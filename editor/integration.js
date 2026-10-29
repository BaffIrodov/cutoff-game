/* Godot connection only. The original editor.js and styles.css are unchanged. */
(() => {
    const nativeFetch = window.fetch.bind(window);
    const readOnlyIds = new Set();
    window.fetch = async (input, options) => {
        const response = await nativeFetch(input, options);
        if (input === '/api/editor/maps' && (!options?.method || options.method === 'GET') && response.ok) {
            const maps = await response.clone().json();
            readOnlyIds.clear();
            maps.filter(map => map.readOnly).forEach(map => readOnlyIds.add(map.id));
        }
        return response;
    };

    window.addEventListener('DOMContentLoaded', () => {
        history.replaceState(null, '', '/');
        const byId = id => document.getElementById(id);
        const integration = document.createElement('div');
        integration.className = 'godot-integration';
        integration.innerHTML = '<div><strong>Godot</strong> · <span id="godot-connection">Проверка соединения…</span></div>' +
            '<p class="hint">«Сохранить карту» сохраняет рабочую копию в папке maps. Для совместной игры загрузите её на игровой сервер.</p>' +
            '<div class="actions"><button id="godot-publish" class="secondary" type="button">Сохранить и загрузить на игровой сервер</button>' +
            '<label id="godot-key-label" class="hidden">Ключ загрузки <input id="godot-upload-key" type="password" autocomplete="off"></label></div>' +
            '<p id="godot-status" class="editor-message" role="status" aria-live="polite"></p>';
        byId('editor-status').after(integration);

        const importInput = document.createElement('input');
        importInput.type = 'file';
        importInput.accept = '.map,application/json';
        importInput.className = 'hidden';
        const importButton = document.createElement('button');
        importButton.id = 'editor-import';
        importButton.textContent = 'Открыть .map…';
        importButton.className = 'secondary';
        byId('editor-menu-back').before(importButton);
        importButton.after(importInput);
        importButton.addEventListener('click', () => importInput.click());

        function showStatus(message, error = false) {
            byId('godot-status').textContent = message;
            byId('godot-status').classList.toggle('error', error);
        }

        async function jsonRequest(path, options = {}) {
            const response = await nativeFetch(path, {
                ...options,
                headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
                signal: AbortSignal.timeout(25000)
            });
            const result = await response.json();
            if (!response.ok) throw new Error(result.message || 'Запрос не выполнен.');
            return result;
        }

        async function updateConnection() {
            try {
                const state = await jsonRequest('/api/integration/state');
                byId('godot-connection').textContent = state.connected
                    ? `игра подключена к ${state.server}` : 'игра не подключена к серверу; локальное сохранение доступно';
                byId('connection-status').textContent = 'Локальный редактор · Godot';
                byId('godot-key-label').classList.toggle('hidden', !state.tokenRequired);
                byId('godot-publish').disabled = !state.canUpload || publishing;
            } catch {
                byId('godot-connection').textContent = 'нет связи с игрой — откройте редактор из окна «Отсечка»';
                byId('godot-publish').disabled = true;
            }
        }

        // Opening a protected original creates an ordinary editable copy through the
        // original editor's own copy command. Its save path can never target production.
        byId('editor-open-map').addEventListener('click', event => {
            if (!readOnlyIds.has(byId('editor-map-select').value)) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            byId('editor-copy-map').click();
        }, true);

        // The UI core stays untouched; observe its existing save result before upload.
        function saveCurrentMap() {
            return new Promise((resolve, reject) => {
                const status = byId('editor-status');
                const save = byId('editor-save');
                const timer = setTimeout(() => finish(new Error('Сохранение не подтверждено. Черновик оставлен в браузере.')), 20000);
                const observer = new MutationObserver(check);
                function finish(error) {
                    clearTimeout(timer);
                    observer.disconnect();
                    if (error) reject(error); else resolve(byId('editor-map-id').value);
                }
                function check() {
                    if (save.disabled) return;
                    if (status.classList.contains('error')) finish(new Error(status.textContent));
                    else if (/сохранена|сохранён|сохранен/.test(status.textContent)) finish();
                }
                observer.observe(status, { childList: true, subtree: true, attributes: true });
                observer.observe(save, { attributes: true });
                save.click();
                queueMicrotask(check);
            });
        }

        let publishing = false;
        byId('godot-publish').addEventListener('click', async () => {
            if (publishing) return;
            publishing = true;
            byId('godot-publish').disabled = true;
            showStatus('Сохранение рабочей копии…');
            try {
                const mapId = await saveCurrentMap();
                showStatus('Рабочая копия сохранена. Загрузка на игровой сервер…');
                const result = await jsonRequest('/api/integration/upload', {
                    method: 'POST', body: JSON.stringify({ mapId, credential: byId('godot-upload-key').value })
                });
                showStatus(result.message + ' Вернитесь в игру, чтобы начать тренировку или матч.');
            } catch (error) { showStatus(error.message, true); }
            finally { publishing = false; updateConnection(); }
        });

        importInput.addEventListener('change', async () => {
            const file = importInput.files?.[0];
            if (!file) return;
            try {
                if (file.size > 524288) throw new Error('Карта больше 512 КБ.');
                const result = await jsonRequest('/api/integration/import', { method: 'POST', body: await file.text() });
                const select = byId('editor-map-select');
                const observer = new MutationObserver(() => {
                    if (![...select.options].some(option => option.value === result.id)) return;
                    observer.disconnect();
                    select.value = result.id;
                    byId('editor-open-map').click();
                });
                observer.observe(select, { childList: true });
                byId('open-level-editor').click();
            } catch (error) {
                const message = byId('editor-menu-message');
                message.textContent = error.message;
                message.classList.remove('hidden');
                message.classList.add('error');
            }
            importInput.value = '';
        });

        // Clarify the original HTTP server's wording for this local editing service.
        const status = byId('editor-status');
        new MutationObserver(() => {
            if (status.textContent.includes('сохранена на сервере'))
                status.textContent = status.textContent.replace('сохранена на сервере', 'сохранена локально');
        }).observe(status, { childList: true, subtree: true });

        byId('open-level-editor').click();
        updateConnection();
        setInterval(updateConnection, 3000);
    });
})();
