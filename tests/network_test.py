"""Run a real Godot server and two Godot clients through impaired local UDP links."""
from __future__ import annotations
import heapq
import argparse
import json
import os
from pathlib import Path
import random
import socket
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"
ENGINE = next((ROOT / "tools/godot").glob("*_console.exe"))


class Link(threading.Thread):
    def __init__(self, port: int, server_port: int, seed: int):
        super().__init__(daemon=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", port))
        self.sock.settimeout(0.005)
        self.server = ("127.0.0.1", server_port)
        self.client = None
        self.pending = []
        self.rng = random.Random(seed)
        self.running = True
        self.dropped = 0
        self.forwarded = 0
        self.serial = 0

    def run(self):
        while self.running:
            try:
                payload, source = self.sock.recvfrom(65535)
                if source == self.server:
                    destination = self.client
                else:
                    self.client = source
                    destination = self.server
                if destination:
                    if self.rng.random() < 0.03:
                        self.dropped += 1
                    else:
                        self.serial += 1
                        heapq.heappush(self.pending, (time.monotonic() + 0.025 + self.rng.random() * 0.015, self.serial, payload, destination))
            except (socket.timeout, ConnectionResetError):
                pass
            while self.pending and self.pending[0][0] <= time.monotonic():
                _, _, payload, destination = heapq.heappop(self.pending)
                self.sock.sendto(payload, destination)
                self.forwarded += 1
        self.sock.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pack-server', action='store_true')
    parser.add_argument('--players', type=int, choices=(2, 4), default=2)
    parser.add_argument('--custom-map', action='store_true')
    args = parser.parse_args()
    ARTIFACTS.mkdir(exist_ok=True)
    roles = ['host', 'guest'] if args.players == 2 else ['host', 'guest', 'guest2', 'guest3']
    for name in ["network-room.json", *[f'network-{role}.json' for role in roles]]:
        (ARTIFACTS / name).unlink(missing_ok=True)
    processes = []
    logs = []
    links = [Link(19121 + i, 19120, 17 + i * 12) for i in range(args.players)]
    try:
        for link in links:
            link.start()
        map_args = ['--allow-map-upload', '--map-upload-token=integration-test-token', f'--map-directory={ARTIFACTS / ("network-maps-" + str(time.time_ns()))}'] if args.custom_map else []
        launches = [('server', ['--server', '--port=19120', *map_args])] + [
            (role, [f'--bot={role}', f'--port={19121 + i}', f'--players={args.players}', *(['--custom-map'] if args.custom_map else [])]) for i, role in enumerate(roles)
        ]
        for role, arguments in launches:
            log = (ARTIFACTS / f"network-{role}.stdout.log").open("w", encoding="utf-8")
            logs.append(log)
            pack_arguments = ["--main-pack", str(ROOT / 'build/linux-server/cutoff.pck')] if args.pack_server and role == 'server' else []
            process = subprocess.Popen(
                [str(ENGINE), "--headless", "--path", str(ROOT), *pack_arguments, "--log-file", str(ARTIFACTS / f"network-{role}.godot.log"), "--", *arguments],
                cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            processes.append(process)
            if role == "server":
                time.sleep(0.8)
        codes = [process.wait(timeout=55) for process in processes[1:]]
        reports = [json.loads((ARTIFACTS / f"network-{role}.json").read_text(encoding="utf-8")) for role in roles]
        summary = {"exit_codes": codes, "latency_per_direction_ms": "25–40", "configured_udp_loss": 0.03,
                   "custom_map": args.custom_map, "packed_server": args.pack_server,
                   "links": [{"dropped": x.dropped, "forwarded": x.forwarded} for x in links], "clients": reports}
        (ARTIFACTS / "network-test.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        if any(codes) or not all(report["success"] for report in reports) or (args.custom_map and not all(report["custom_map_checked"] for report in reports)):
            raise SystemExit(1)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        for link in links:
            link.running = False
            link.join(timeout=1)
        for log in logs:
            log.close()


if __name__ == "__main__":
    main()
