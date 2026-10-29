"""Real Godot HTTP editor, disk saves and ENet upload. Uses no Java or web framework."""
from __future__ import annotations
import argparse
import hashlib
import http.cookiejar
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
ENGINE = next((ROOT / 'tools/godot').glob('*_console.exe'))
ARTIFACTS = ROOT / 'artifacts'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pack', action='store_true')
    parser.add_argument('--serve', action='store_true', help='Keep the isolated editor open for manual browser review')
    args = parser.parse_args()
    fixture = ARTIFACTS / ('editor-http-' + uuid.uuid4().hex)
    fixture.mkdir(parents=True)
    token = uuid.uuid4().hex
    base = 'http://127.0.0.1:19140'
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    processes, logs = [], []
    checks = []

    def check(condition, message):
        if not condition:
            raise AssertionError(message)
        checks.append(message)

    def request(path, method='GET', value=None, headers=None, anonymous=False):
        body = json.dumps(value, ensure_ascii=False).encode('utf-8') if value is not None else None
        req = urllib.request.Request(base + path, body, method=method,
                                     headers={'Origin': base, 'Content-Type': 'application/json', **(headers or {})})
        client = urllib.request.build_opener(urllib.request.ProxyHandler({})) if anonymous else opener
        try:
            response = client.open(req, timeout=12)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            data = response.read()
            parsed = json.loads(data) if 'application/json' in response.headers.get('Content-Type', '') else data
            return response.status, parsed, response.headers

    def launch(role, arguments):
        log = (fixture / (role + '.log')).open('w', encoding='utf-8')
        logs.append(log)
        pack = ['--main-pack', str(ROOT / 'build/windows/cutoff.pck')] if args.pack else []
        child = subprocess.Popen([str(ENGINE), '--headless', '--path', str(ROOT), *pack,
                                  '--log-file', str(fixture / (role + '-godot.log')), '--', *arguments],
                                 cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                 creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        processes.append(child)

    try:
        launch('server', ['--server', '--port=19141', '--allow-map-upload', '--map-upload-token=editor-test-key',
                          f'--map-directory={fixture / "server_maps"}'])
        time.sleep(0.5)
        launch('editor', ['--editor-http', '--no-browser', '--editor-port=19140', f'--editor-session={token}',
                          f'--editor-maps={fixture / "maps"}', '--autoconnect', '--connect=127.0.0.1', '--port=19141'])
        deadline = time.monotonic() + 12
        while True:
            try:
                status, html, headers = request('/?token=' + token)
                break
            except (OSError, urllib.error.URLError):
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.15)
        check(status == 200 and b'editor-properties' in html, 'Original editor HTML served by Godot')
        check('HttpOnly' in headers.get('Set-Cookie', ''), 'Local editing session established')
        check(request('/api/editor/maps', anonymous=True)[0] == 403, 'Unauthenticated request rejected')
        for filename in ('editor.js', 'styles.css'):
            status, content, _ = request('/' + filename)
            check(status == 200 and content == (ROOT / 'editor' / filename).read_bytes(), 'Original asset byte-identical: ' + filename)
        status, catalog, _ = request('/api/editor/maps')
        check(status == 200 and catalog[0]['readOnly'], 'Production map listed as protected')
        status, template, _ = request('/api/editor/maps/template')
        check(status == 200 and template['id'] == 'default' and len(catalog) == 1, 'Original template served without becoming a production map')
        _, original, original_headers = request('/api/editor/maps/emergency-reactor-copy')
        check(hashlib.sha256((ROOT / 'maps/emergency-reactor-copy.map').read_bytes()).hexdigest() ==
              'bba06fe78c0d82944db42b4449fb4097b7f9537f8eff29869b9a4af2e0d67d8f', 'Production bytes preserved')
        check(request('/api/editor/maps/emergency-reactor-copy', 'PUT', original,
                      {'If-Match': original_headers['ETag']})[0] == 403, 'HTTP cannot overwrite production')
        copy = json.loads(json.dumps(original))
        copy.update(id='browser-editor-test', name='Browser editor test')
        copy['mobs'][0]['level'] = 2
        copy['mobs'][0]['route']['enabled'] = True
        copy['mobs'][0]['route']['points'][0] = {'x': 900, 'y': 450}
        check(request('/api/editor/maps', 'POST', copy, {'Origin': 'https://unrelated.example'})[0] == 403,
              'Other websites cannot save maps')
        status, saved, saved_headers = request('/api/editor/maps', 'POST', copy)
        check(status == 201 and saved['mobs'][0]['route'] == copy['mobs'][0]['route'], 'Editor saves mob properties and route')
        disk = fixture / 'maps/browser-editor-test.map'
        check(json.loads(disk.read_text(encoding='utf-8')) == copy, 'Map saved to working directory')
        check(request('/api/editor/maps', 'POST', copy)[0] == 409, 'Duplicate create cannot overwrite map')
        copy['name'] = 'Updated browser map'
        status, _, updated_headers = request('/api/editor/maps/' + copy['id'], 'PUT', copy, {'If-Match': saved_headers['ETag']})
        check(status == 200 and updated_headers['ETag'] != saved_headers['ETag'], 'Successful save updates ETag')
        stale = {**copy, 'name': 'Stale version'}
        check(request('/api/editor/maps/' + copy['id'], 'PUT', stale, {'If-Match': saved_headers['ETag']})[0] == 412,
              'Concurrent stale tab cannot lose edits')
        check(request('/api/editor/maps/' + copy['id'])[1]['name'] == copy['name'], 'Conflict leaves disk version intact')
        status, imported, _ = request('/api/integration/import', 'POST', original)
        check(status == 201 and imported['id'] != original['id'], 'Import creates separate editable copy of production')
        invalid = json.loads(json.dumps(copy))
        invalid['mobs'][0]['spawnTrigger'] = 'missing-event'
        check(request('/api/editor/maps/' + copy['id'], 'PUT', invalid, {'If-Match': updated_headers['ETag']})[0] == 400,
              'Godot rejects invalid trigger links')
        deadline = time.monotonic() + 8
        while not request('/api/integration/state')[1]['connected']:
            if time.monotonic() > deadline:
                raise AssertionError('Editor did not connect to ENet server')
            time.sleep(0.1)
        check(request('/api/integration/upload', 'POST', {'mapId': copy['id'], 'credential': 'wrong'})[0] == 400,
              'Wrong game-server upload key is rejected')
        status, result, _ = request('/api/integration/upload', 'POST', {'mapId': copy['id'], 'credential': 'editor-test-key'})
        check(status == 200 and result['uploaded'], 'Browser-edited map uploaded through actual Godot networking')
        _, state, _ = request('/api/integration/state')
        check(state['mapId'] == copy['id'], 'Game client automatically selects uploaded map')
        stored = fixture / 'server_maps' / (state['mapKey'] + '.map')
        check(stored.exists() and json.loads(stored.read_text(encoding='utf-8')) == copy, 'Game server stores exact edited map')
        report = {'checks': len(checks), 'failures': [], 'packed': args.pack, 'passed': checks, 'fixture': str(fixture)}
        destination = ARTIFACTS / ('editor-http-test-packed.json' if args.pack else 'editor-http-test.json')
        destination.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print(f'EDITOR_HTTP_TEST checks={len(checks)} failures=0 packed={args.pack}')
        if args.serve:
            stop = ARTIFACTS / 'editor-review.stop'
            stop.unlink(missing_ok=True)
            (ARTIFACTS / 'editor-review.json').write_text(json.dumps({'url': base + '/?token=' + token, 'fixture': str(fixture)}), encoding='utf-8')
            print('EDITOR_REVIEW_READY', flush=True)
            deadline = time.monotonic() + 1200
            while not stop.exists() and time.monotonic() < deadline:
                time.sleep(0.2)
    finally:
        for child in processes:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
