(() => {
    const editor = {
        maps: [],
        map: null,
        loadedId: null,
        isNew: false,
        selectedKey: null,
        drag: null,
        dirty: false,
        zoom: 0.45,
        history: [],
        savedState: null,
        revision: null,
        saving: false,
        draftKey: null,
        draftTimer: null
    };

    const elements = {
        mainMenu: document.getElementById('menu-screen'),
        openEditor: document.getElementById('open-level-editor'),
        browser: document.getElementById('editor-menu-screen'),
        mapSelect: document.getElementById('editor-map-select'),
        openMap: document.getElementById('editor-open-map'),
        copyMap: document.getElementById('editor-copy-map'),
        newMap: document.getElementById('editor-new-map'),
        emptyMap: document.getElementById('editor-empty-map'),
        browserBack: document.getElementById('editor-menu-back'),
        browserMessage: document.getElementById('editor-menu-message'),
        screen: document.getElementById('editor-screen'),
        back: document.getElementById('editor-back'),
        undo: document.getElementById('editor-undo'),
        save: document.getElementById('editor-save'),
        export: document.getElementById('editor-export'),
        restoreDraft: document.getElementById('editor-restore-draft'),
        mapId: document.getElementById('editor-map-id'),
        mapName: document.getElementById('editor-map-name'),
        worldWidth: document.getElementById('editor-world-width'),
        worldHeight: document.getElementById('editor-world-height'),
        zoom: document.getElementById('editor-zoom'),
        gridSnap: document.getElementById('editor-grid-snap'),
        addType: document.getElementById('editor-add-type'),
        add: document.getElementById('editor-add'),
        viewport: document.getElementById('editor-viewport'),
        canvas: document.getElementById('editor-canvas'),
        objectSelect: document.getElementById('editor-object-select'),
        properties: document.getElementById('editor-properties'),
        remove: document.getElementById('editor-delete'),
        status: document.getElementById('editor-status')
    };

    const context = elements.canvas.getContext('2d');
    const deepCopy = value => JSON.parse(JSON.stringify(value));
    const clamp = (value, minimum, maximum) => Math.max(minimum, Math.min(maximum, value));
    const WORLD_CREATED_TRIGGER = 'world-created';
    const DRAFT_PREFIX = 'cutoff.editor.draft.v1:';
    let draftTabId;
    try {
        draftTabId = sessionStorage.getItem('cutoff.editor.tab') || `${Date.now()}-${Math.random()}`;
        sessionStorage.setItem('cutoff.editor.tab', draftTabId);
    } catch { draftTabId = `${Date.now()}-${Math.random()}`; }
    const MOB_DEFAULTS = {
        MELEE: { health: 60, ammo: 0 },
        RANGED: { health: 60, ammo: 15 },
        ASSAULT: { health: 60, ammo: 60 },
        GRENADIER: { health: 60, ammo: 5 },
        BOSS_ASSAULT: { health: 500, ammo: 120 },
        BOSS_GRENADIER: { health: 300, ammo: 10 }
    };

    function showScreen(screen) {
        document.querySelectorAll('[data-screen]').forEach(candidate => {
            candidate.classList.toggle('hidden', candidate !== screen);
        });
    }

    async function request(path, options = {}) {
        const { withMeta = false, ...fetchOptions } = options;
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 15000);
        try {
        const response = await fetch(path, {
            ...fetchOptions,
            signal: controller.signal,
            cache: 'no-store',
            headers: {
                ...(options.body ? { 'Content-Type': 'application/json' } : {}),
                ...(options.headers || {})
            }
        });
        const text = await response.text();
        let body = null;
        if (text) {
            try {
                body = JSON.parse(text);
            } catch {
                body = text;
            }
        }
        if (!response.ok) {
            const message = body?.detail || body?.message || body?.error
                || (typeof body === 'string' ? body : `Ошибка HTTP ${response.status}`);
            const error = new Error(message);
            error.status = response.status;
            throw error;
        }
        return withMeta ? { map: body, revision: response.headers.get('ETag') } : body;
        } catch (error) {
            if (error.name === 'AbortError') throw new Error('Сервер не ответил за 15 секунд. Сохранение не подтверждено. Черновик оставлен в браузере — повторите сохранение.');
            if (error instanceof TypeError) throw new Error('Нет связи с сервером. Карта не подтверждена как сохранённая; черновик оставлен в браузере.');
            throw error;
        } finally { clearTimeout(timeout); }
    }

    async function openMapBrowser(message = '') {
        showScreen(elements.browser);
        setBrowserMessage('Загрузка карт…');
        try {
            editor.maps = await request('/api/editor/maps');
            elements.mapSelect.replaceChildren(...editor.maps.map(map => {
                const option = document.createElement('option');
                option.value = map.id;
                option.textContent = `${map.name} · ${map.id}`;
                return option;
            }));
            elements.openMap.disabled = editor.maps.length === 0;
            elements.copyMap.disabled = editor.maps.length === 0;
            setBrowserMessage(message, false);
        } catch (error) {
            setBrowserMessage(error.message, true);
        }
    }

    function setBrowserMessage(message, error = false) {
        elements.browserMessage.textContent = message;
        elements.browserMessage.classList.toggle('hidden', !message);
        elements.browserMessage.classList.toggle('error', error);
    }

    async function loadExistingMap() {
        const mapId = elements.mapSelect.value;
        if (!mapId) return;
        setBrowserMessage('Загрузка карты…');
        try {
            const result = await request(`/api/editor/maps/${encodeURIComponent(mapId)}`, { withMeta: true });
            loadIntoEditor(result.map, false, mapId, null, result.revision);
            const draft = drafts().find(value => value.loadedId === mapId);
            if (draft && JSON.stringify(normalizeMap(deepCopy(draft.map))) !== editor.savedState
                    && window.confirm('В браузере есть несохранённый черновик этой карты. Восстановить его?')) {
                restoreDraft(draft);
            }
        } catch (error) {
            setBrowserMessage(error.message, true);
        }
    }

    async function createMapFromTemplate() {
        setBrowserMessage('Подготовка нового туннеля…');
        try {
            const map = deepCopy(await request('/api/editor/maps/template'));
            map.id = nextMapId('new-tunnel');
            map.name = 'Новый туннель';
            loadIntoEditor(map, true, null);
        } catch (error) {
            setBrowserMessage(error.message, true);
        }
    }

    async function createMapCopy() {
        const mapId = elements.mapSelect.value;
        if (!mapId) return;
        setBrowserMessage('Создание копии карты…');
        try {
            const source = deepCopy(await request(`/api/editor/maps/${encodeURIComponent(mapId)}`));
            source.id = nextMapId(`${mapId}-copy`);
            source.name = `${source.name} — копия`;
            loadIntoEditor(source, true, null,
                `Создана копия карты «${source.name.replace(/ — копия$/, '')}». Задайте ID и сохраните её отдельно.`);
        } catch (error) {
            setBrowserMessage(error.message, true);
        }
    }

    function createEmptyMap() {
        const map = {
            formatVersion: 4,
            id: nextMapId('empty-tunnel'),
            name: 'Пустой туннель',
            worldWidth: 2400,
            worldHeight: 720,
            playerSpawns: [
                { x: 100, y: 250 }, { x: 100, y: 325 },
                { x: 100, y: 395 }, { x: 100, y: 470 }
            ],
            labels: [],
            obstacles: [],
            entrance: {
                gate: { x: 250, y: 70, width: 24, height: 580 },
                console: { x: 185, y: 360 },
                triggers: { opened: 'entrance-opened' }
            },
            checkpoints: [{
                id: 'checkpoint-1',
                platforms: [
                    { x: 2080, y: 230 }, { x: 2160, y: 230 },
                    { x: 2080, y: 490 }, { x: 2160, y: 490 }
                ],
                exitGate: { x: 2280, y: 70, width: 24, height: 580 },
                maximumSurvivors: 4,
                triggers: {
                    'platform-1': 'checkpoint-1-platform-1',
                    'platform-2': 'checkpoint-1-platform-2',
                    'platform-3': 'checkpoint-1-platform-3',
                    'platform-4': 'checkpoint-1-platform-4',
                    activated: 'checkpoint-1-activated',
                    cleared: 'checkpoint-1-cleared',
                    failed: 'checkpoint-1-failed'
                }
            }],
            weaponPickups: [],
            healthBoostPickups: [],
            lootCrates: [{ x: 690, y: 320 }, { x: 750, y: 400 }],
            intelTerminals: [],
            mobs: [],
            cooperationGates: [],
            trustPockets: [],
            serviceBridges: [],
            separationGates: [],
            finalRelays: [],
            triggerAreas: []
        };
        loadIntoEditor(map, true, null,
            'Создан пустой игровой туннель с обязательными стартом, входом, одной отсечкой и парой лут-ящиков.');
    }

    function nextMapId(prefix) {
        const ids = new Set(editor.maps.map(map => map.id));
        let base = String(prefix || 'new-map').toLowerCase()
            .replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '') || 'new-map';
        base = base.slice(0, 40).replace(/-+$/g, '');
        if (!ids.has(base)) return base;
        let suffix = 2;
        while (ids.has(`${base.slice(0, 39 - String(suffix).length)}-${suffix}`)) suffix++;
        return `${base.slice(0, 39 - String(suffix).length)}-${suffix}`;
    }

    function loadIntoEditor(map, isNew, loadedId, statusMessage = null, revision = null) {
        editor.map = normalizeMap(map);
        editor.isNew = isNew;
        editor.loadedId = loadedId;
        editor.selectedKey = null;
        editor.drag = null;
        editor.dirty = isNew;
        editor.zoom = 0.45;
        editor.history = [];
        editor.savedState = isNew ? null : JSON.stringify(editor.map);
        editor.revision = revision;
        editor.draftKey = `${DRAFT_PREFIX}${draftTabId}:${loadedId || map.id}`;
        updateUndoButton();

        map = editor.map;
        elements.mapId.value = map.id;
        elements.mapId.disabled = !isNew;
        elements.mapName.value = map.name;
        elements.worldWidth.value = map.worldWidth;
        elements.worldHeight.value = map.worldHeight;
        elements.zoom.value = String(Math.round(editor.zoom * 100));
        showScreen(elements.screen);
        resizeCanvas();
        renderEditor();
        elements.viewport.scrollLeft = 0;
        elements.viewport.scrollTop = 0;
        setStatus(statusMessage || (isNew
            ? 'Создана новая карта из туннельного шаблона. Задайте ID и название.'
            : `Открыта карта «${map.name}».`), false, isNew);
        if (isNew) persistDraft();
    }

    function normalizeMap(map) {
        map.formatVersion = 4;
        map.cooperationGates ||= map.cooperation ? [map.cooperation] : [];
        map.trustPockets ||= map.trustPocket ? [map.trustPocket] : [];
        map.serviceBridges ||= map.serviceBridge ? [map.serviceBridge] : [];
        map.separationGates ||= map.separationGate ? [map.separationGate] : [];
        map.finalRelays ||= map.finalRelay ? [map.finalRelay] : [];
        delete map.cooperation;
        delete map.trustPocket;
        delete map.serviceBridge;
        delete map.separationGate;
        delete map.finalRelay;
        map.triggerAreas ||= [];
        map.healthBoostPickups ||= [];
        ensureTriggers(map.entrance, 'entrance', ['opened']);
        map.cooperationGates.forEach((gate, index) => {
            gate.id ||= `cooperation-${index + 1}`;
            gate.requiredPlayers ||= Math.max(2, gate.plates.length);
            delete gate.maximumSurvivors;
            gate.adaptiveToTeamSize ??= false;
            ensureTriggers(gate, gate.id,
                [...gate.plates.map((_, plateIndex) => `plate-${plateIndex + 1}`), 'opened']);
        });
        map.trustPockets.forEach((value, index) => {
            value.id ||= `trust-pocket-${index + 1}`;
            ensureTriggers(value, value.id, ['plate-pressed', 'plate-released']);
        });
        map.serviceBridges.forEach((value, index) => {
            value.id ||= `service-bridge-${index + 1}`;
            ensureTriggers(value, value.id, ['plate-pressed', 'override-pressed']);
        });
        map.separationGates.forEach((value, index) => {
            value.id ||= `separation-gate-${index + 1}`;
            ensureTriggers(value, value.id,
                value.controls.map((_, controlIndex) => `control-${controlIndex + 1}`));
        });
        map.finalRelays.forEach((value, index) => {
            value.id ||= `final-relay-${index + 1}`;
            ensureTriggers(value, value.id,
                [...value.nodes.map((_, nodeIndex) => `node-${nodeIndex + 1}`), 'opened']);
        });
        map.checkpoints.forEach((checkpoint, index) => {
            checkpoint.id ||= `checkpoint-${index + 1}`;
            checkpoint.maximumSurvivors ||= 4;
            ensureTriggers(checkpoint, checkpoint.id, [
                ...checkpoint.platforms.map((_, platformIndex) => `platform-${platformIndex + 1}`),
                'activated', 'cleared', 'failed'
            ]);
        });
        map.triggerAreas.forEach((area, index) => {
            area.id ||= `trigger-area-${index + 1}`;
            area.trigger ||= `${area.id}-entered`;
        });
        map.intelTerminals.forEach(terminal => {
            terminal.checkpointId ||= map.checkpoints[clamp((terminal.checkpoint || 1) - 1, 0,
                map.checkpoints.length - 1)]?.id;
        });
        map.mobs.forEach(mob => {
            mob.level ||= 1;
            const defaults = MOB_DEFAULTS[mob.type] || MOB_DEFAULTS.MELEE;
            mob.health ??= defaults.health;
            mob.ammo ??= defaults.ammo;
            mob.spawnTrigger ||= WORLD_CREATED_TRIGGER;
            // Keep destinations as an array: the MVP edits one final point, but adding a
            // multi-point route later will not require migrating existing .map files.
            mob.route ||= {
                enabled: false,
                points: [{ x: mob.x, y: mob.y }],
                startTrigger: WORLD_CREATED_TRIGGER
            };
            mob.route.enabled ??= false;
            mob.route.points ||= [{ x: mob.x, y: mob.y }];
            if (mob.route.points.length === 0) mob.route.points.push({ x: mob.x, y: mob.y });
            mob.route.startTrigger ||= WORLD_CREATED_TRIGGER;
        });
        return map;
    }

    function ensureTriggers(root, prefix, actions) {
        root.triggers ||= {};
        actions.forEach(action => root.triggers[action] ||= `${prefix}-${action}`);
    }

    function allTriggerNames() {
        if (!editor.map) return [WORLD_CREATED_TRIGGER];
        const map = editor.map;
        const names = [WORLD_CREATED_TRIGGER, ...Object.values(map.entrance.triggers || {})];
        [map.cooperationGates, map.trustPockets, map.serviceBridges,
            map.separationGates, map.finalRelays, map.checkpoints]
            .forEach(collection => collection.forEach(root => names.push(...Object.values(root.triggers || {}))));
        map.triggerAreas.forEach(area => names.push(area.trigger));
        return names;
    }

    function availableTriggers() {
        return [...new Set(allTriggerNames())];
    }

    function triggerFields(triggers, definitions) {
        return definitions.map(([property, label]) => ({
            target: triggers,
            property,
            label,
            type: 'text',
            triggerName: true
        }));
    }

    function renameTriggerReferences(previousName, nextName) {
        if (!previousName || previousName === nextName) return;
        editor.map.mobs.forEach(mob => {
            if (mob.spawnTrigger === previousName) mob.spawnTrigger = nextName;
            if (mob.route.startTrigger === previousName) mob.route.startTrigger = nextName;
        });
    }

    function triggerNamesFromRoot(root) {
        if (!root) return [];
        if (root.trigger) return [root.trigger];
        return Object.values(root.triggers || {});
    }

    function resetRemovedTriggerReferences(triggerNames) {
        const removed = new Set(triggerNames);
        editor.map.mobs.forEach(mob => {
            if (removed.has(mob.spawnTrigger)) mob.spawnTrigger = WORLD_CREATED_TRIGGER;
            if (removed.has(mob.route.startTrigger)) mob.route.startTrigger = WORLD_CREATED_TRIGGER;
        });
    }

    function entityList() {
        if (!editor.map) return [];
        const map = editor.map;
        const entities = [];
        const addPoint = (key, title, group, data, visual, options = {}) => entities.push({
            key, title, group, data, visual, shape: 'point', radius: options.radius || 18,
            collection: options.collection || null,
            bundleCollection: options.bundleCollection || null,
            bundle: options.bundle || null,
            minimum: options.minimum ?? 0,
            deleteMode: options.deleteMode || 'single',
            fields: options.fields || []
        });
        const addRect = (key, title, group, data, visual, options = {}) => entities.push({
            key, title, group, data, visual, shape: 'rect', resizable: true,
            collection: options.collection || null,
            bundleCollection: options.bundleCollection || null,
            bundle: options.bundle || null,
            deleteMode: options.deleteMode || 'single',
            minimum: options.minimum ?? 0,
            fields: options.fields || []
        });

        map.playerSpawns.forEach((point, index) =>
            addPoint(`spawn-${index}`, `Точка появления ${index + 1}`, 'Старт игроков', point, 'spawn', { radius: 16 }));
        map.labels.forEach((label, index) =>
            addPoint(`label-${index}`, `Подпись: ${label.text}`, 'Подписи зон', label, 'label', {
                collection: map.labels,
                fields: [{ property: 'text', label: 'Текст', type: 'text' }]
            }));
        map.obstacles.forEach((obstacle, index) =>
            addRect(`obstacle-${index}`, `Препятствие ${index + 1}`, 'Стены и препятствия', obstacle, 'obstacle', {
                collection: map.obstacles
            }));

        addRect('entrance-gate', 'Входной шлюз', 'Ворота и опасные зоны', map.entrance.gate, 'gate', {
            bundle: map.entrance,
            fields: triggerFields(map.entrance.triggers, [
                ['opened', 'Триггер: шлюз открыт']
            ])
        });
        addPoint('entrance-console', 'Пульт входного шлюза', 'Пульты и плиты', map.entrance.console, 'console');

        map.cooperationGates.forEach((bundle, bundleIndex) => {
            const title = ['', '', 'Парный', 'Тройной', 'Четверной'][bundle.requiredPlayers] || 'Кооперативный';
            const options = { bundle, bundleCollection: map.cooperationGates, deleteMode: 'bundle' };
            addRect(`cooperation-${bundleIndex}-gate`, `${title} шлюз · ${bundle.id}`,
                'Связанные шлюзы', bundle.gate, 'gate', {
                    ...options,
                    fields: [
                        { target: bundle, property: 'id', label: 'ID связи', type: 'text', readonly: true },
                        ...triggerFields(bundle.triggers, [
                            ...bundle.plates.map((_, index) =>
                                [`plate-${index + 1}`, `Триггер: плита ${index + 1}`]),
                            ['opened', 'Триггер: шлюз открыт']
                        ])
                    ]
                });
            bundle.plates.forEach((plate, index) => addPoint(
                `cooperation-${bundleIndex}-plate-${index}`, `${title} шлюз: плита ${index + 1}`,
                'Связанные шлюзы', plate, 'plate', { ...options, radius: 28 }));
        });

        map.trustPockets.forEach((bundle, bundleIndex) => {
            const options = { bundle, bundleCollection: map.trustPockets, deleteMode: 'bundle' };
            addRect(`trust-${bundleIndex}-gate`, `Заслон кармана · ${bundle.id}`, 'Карманы доверия', bundle.gate,
                'gate', { ...options, fields: [
                    { target: bundle, property: 'id', label: 'ID связи', type: 'text', readonly: true },
                    ...triggerFields(bundle.triggers, [
                        ['plate-pressed', 'Триггер: плита нажата'],
                        ['plate-released', 'Триггер: плита отпущена']
                    ])
                ] });
            addRect(`trust-${bundleIndex}-fire`, `Пожар кармана · ${bundle.id}`, 'Карманы доверия', bundle.pocket, 'fire', options);
            addPoint(`trust-${bundleIndex}-plate`, `Плита кармана · ${bundle.id}`, 'Карманы доверия', bundle.plate,
                'plate', { ...options, radius: 28 });
        });

        map.serviceBridges.forEach((bundle, bundleIndex) => {
            const options = { bundle, bundleCollection: map.serviceBridges, deleteMode: 'bundle' };
            addRect(`bridge-${bundleIndex}-hazard`, `Аварийный мост · ${bundle.id}`, 'Аварийные мосты', bundle.hazard,
                'electric', { ...options, fields: [
                    { target: bundle, property: 'id', label: 'ID связи', type: 'text', readonly: true },
                    ...triggerFields(bundle.triggers, [
                        ['plate-pressed', 'Триггер: плита нажата'],
                        ['override-pressed', 'Триггер: пульт нажат']
                    ])
                ] });
            addPoint(`bridge-${bundleIndex}-plate`, `Плита моста · ${bundle.id}`, 'Аварийные мосты', bundle.plate,
                'plate', { ...options, radius: 30 });
            addPoint(`bridge-${bundleIndex}-override`, `Пульт моста · ${bundle.id}`, 'Аварийные мосты',
                bundle.overrideConsole, 'console', options);
        });

        map.separationGates.forEach((bundle, bundleIndex) => {
            const options = { bundle, bundleCollection: map.separationGates, deleteMode: 'bundle' };
            addRect(`separation-${bundleIndex}-gate`, `Разделяющий заслон · ${bundle.id}`, 'Разделяющие заслоны',
                bundle.gate, 'gate', { ...options, fields: [
                    { target: bundle, property: 'id', label: 'ID связи', type: 'text', readonly: true },
                    ...triggerFields(bundle.triggers, bundle.controls.map((_, index) =>
                        [`control-${index + 1}`, `Триггер: кнопка ${index + 1}`]))
                ] });
            bundle.controls.forEach((control, index) => addPoint(
                `separation-${bundleIndex}-control-${index}`, `Заслон ${bundle.id}: кнопка ${index + 1}`,
                'Разделяющие заслоны', control, 'console', options));
        });

        map.finalRelays.forEach((bundle, bundleIndex) => {
            const options = { bundle, bundleCollection: map.finalRelays, deleteMode: 'bundle' };
            addRect(`relay-${bundleIndex}-gate`, `Релейный шлюз · ${bundle.id}`, 'Релейные шлюзы', bundle.gate,
                'gate', { ...options, fields: [
                    { target: bundle, property: 'id', label: 'ID связи', type: 'text', readonly: true },
                    ...triggerFields(bundle.triggers, [
                        ...bundle.nodes.map((_, index) =>
                            [`node-${index + 1}`, `Триггер: узел ${index + 1}`]),
                        ['opened', 'Триггер: шлюз открыт']
                    ])
                ] });
            bundle.nodes.forEach((node, index) => addPoint(
                `relay-${bundleIndex}-node-${index}`, `Реле ${bundle.id}: узел ${index + 1}`,
                'Релейные шлюзы', node, 'relay', { ...options, radius: 24 }));
        });

        map.checkpoints.forEach((checkpoint, checkpointIndex) => {
            checkpoint.platforms.forEach((platform, platformIndex) =>
                addPoint(
                    `checkpoint-${checkpointIndex}-platform-${platformIndex}`,
                    `Платформа отсечки ${checkpointIndex + 1}.${platformIndex + 1}`,
                    'Отсечки',
                    platform,
                    'checkpoint',
                    { radius: 30, bundle: checkpoint, bundleCollection: map.checkpoints,
                        deleteMode: 'bundle', minimum: 1 }
                ));
            addRect(
                `checkpoint-${checkpointIndex}-gate`,
                `Выходной шлюз отсечки ${checkpointIndex + 1}`,
                'Отсечки',
                checkpoint.exitGate,
                'checkpoint-gate',
                { bundle: checkpoint, bundleCollection: map.checkpoints, deleteMode: 'bundle', minimum: 1,
                    fields: [
                        { target: checkpoint, property: 'maximumSurvivors',
                            label: 'Макс. игроков после отсечки', type: 'number', min: 1, max: 4, step: 1 },
                        { target: checkpoint, property: 'id', label: 'ID связи', type: 'text', readonly: true },
                        ...triggerFields(checkpoint.triggers, [
                            ...checkpoint.platforms.map((_, index) =>
                                [`platform-${index + 1}`, `Триггер: платформа ${index + 1}`]),
                            ['activated', 'Триггер: проверка началась'],
                            ['cleared', 'Триггер: отсечка пройдена'],
                            ['failed', 'Триггер: отсечка провалена']
                        ])
                    ] }
            );
        });

        map.triggerAreas.forEach((area, index) => addRect(
            `trigger-area-${index}`,
            `Область-триггер · ${area.id}`,
            'Триггеры и маршруты',
            area.area,
            'trigger-area',
            {
                bundle: area,
                bundleCollection: map.triggerAreas,
                fields: [
                    { target: area, property: 'id', label: 'ID области', type: 'text' },
                    { target: area, property: 'trigger', label: 'Триггер: игрок вошёл',
                        type: 'text', triggerName: true }
                ]
            }
        ));

        map.weaponPickups.forEach((weapon, index) =>
            addPoint(`weapon-${index}`, `Огнестрел ${weapon.id}`, 'Предметы и данные', weapon, 'weapon', {
                collection: map.weaponPickups,
                fields: [
                    { property: 'id', label: 'ID', type: 'text' },
                    { property: 'ammo', label: 'Патроны', type: 'number', min: 1, max: 99, step: 1 }
                ]
            }));
        map.healthBoostPickups.forEach((pickup, index) =>
            addPoint(`health-boost-${index}`, `Усилитель здоровья ${index + 1}`,
                'Предметы и данные', pickup, 'health-boost', {
                    collection: map.healthBoostPickups,
                    radius: 18
                }));
        map.lootCrates.forEach((crate, index) =>
            addPoint(`loot-${index}`, `Лут-ящик ${index + 1}`, 'Предметы и данные', crate, 'loot', {
                collection: map.lootCrates
            }));
        map.intelTerminals.forEach((terminal, index) =>
            addPoint(`intel-${index}`, `Данные ${terminal.id}`, 'Предметы и данные', terminal, 'intel', {
                collection: map.intelTerminals,
                fields: [
                    { property: 'id', label: 'ID', type: 'text' },
                    { property: 'checkpointId', label: 'Отсечка', type: 'select',
                        values: map.checkpoints.map(checkpoint => checkpoint.id) }
                ]
            }));
        map.mobs.forEach((mob, index) => {
            addPoint(`mob-${index}`, `Противник ${mob.id}`, 'Противники', mob,
                { MELEE: 'mob-melee', RANGED: 'mob-ranged', ASSAULT: 'mob-assault',
                    GRENADIER: 'mob-grenadier', BOSS_ASSAULT: 'boss-assault',
                    BOSS_GRENADIER: 'boss-grenadier' }[mob.type] || 'mob-melee', {
                    collection: map.mobs,
                    radius: mob.type.startsWith('BOSS_') ? 30 : 18,
                    fields: [
                        { property: 'id', label: 'ID', type: 'text' },
                        { property: 'type', label: 'Тип', type: 'select',
                            values: ['MELEE', 'RANGED', 'ASSAULT', 'GRENADIER',
                                'BOSS_ASSAULT', 'BOSS_GRENADIER'],
                            captions: ['Ближний бой', 'Болтовая винтовка', 'Автомат', 'Гранатомёт',
                                'Босс-автоматчик', 'Босс-гранатомётчик'] },
                        { property: 'health', label: 'HP', type: 'number', min: 1, max: 5000, step: 1 },
                        { property: 'ammo', label: 'Боезапас', type: 'number', min: 0, max: 10000, step: 1 },
                        { property: 'level', label: 'Уровень поведения', type: 'select', values: [1, 2],
                            captions: ['1 · базовый, синий', '2 · зигзаги, красный'] },
                        { property: 'spawnTrigger', label: 'Триггер появления', type: 'select',
                            values: availableTriggers() },
                        { target: mob.route, property: 'enabled', label: 'Использовать маршрут', type: 'select',
                            values: [false, true], captions: ['Нет', 'Да'] },
                        { target: mob.route, property: 'startTrigger', label: 'Триггер начала маршрута',
                            type: 'select', values: availableTriggers() },
                        { target: mob.route.points[0], property: 'x', label: 'Финиш маршрута X',
                            type: 'number', min: 0, max: map.worldWidth, step: 1 },
                        { target: mob.route.points[0], property: 'y', label: 'Финиш маршрута Y',
                            type: 'number', min: 0, max: map.worldHeight, step: 1 }
                    ]
                });
            if (mob.route.enabled) {
                addPoint(`mob-route-${index}`, `Финиш маршрута ${mob.id}`,
                    'Триггеры и маршруты', mob.route.points[0], 'route-target', {
                        radius: 15,
                        bundle: mob,
                        fields: [
                            { target: mob.route, property: 'enabled', label: 'Использовать маршрут', type: 'select',
                                values: [false, true], captions: ['Нет', 'Да'] },
                            { target: mob.route, property: 'startTrigger', label: 'Триггер начала маршрута',
                                type: 'select', values: availableTriggers() }
                        ]
                    });
            }
        });
        return entities;
    }

    function renderEditor() {
        if (!editor.map) return;
        elements.mapId.value = editor.map.id;
        elements.mapName.value = editor.map.name;
        elements.worldWidth.value = editor.map.worldWidth;
        elements.worldHeight.value = editor.map.worldHeight;
        renderObjectSelector();
        renderInspector();
        drawMap();
    }

    function resizeCanvas() {
        elements.canvas.width = editor.map.worldWidth;
        elements.canvas.height = editor.map.worldHeight;
        elements.canvas.style.width = `${editor.map.worldWidth * editor.zoom}px`;
        elements.canvas.style.height = `${editor.map.worldHeight * editor.zoom}px`;
    }

    function renderObjectSelector() {
        const entities = entityList();
        const groups = new Map();
        entities.forEach(entity => {
            if (!groups.has(entity.group)) groups.set(entity.group, []);
            groups.get(entity.group).push(entity);
        });
        const placeholder = document.createElement('option');
        placeholder.value = '';
        placeholder.textContent = '— выберите на карте —';
        const content = [placeholder];
        groups.forEach((items, groupName) => {
            const group = document.createElement('optgroup');
            group.label = groupName;
            items.forEach(entity => {
                const option = document.createElement('option');
                option.value = entity.key;
                option.textContent = entity.title;
                group.append(option);
            });
            content.push(group);
        });
        elements.objectSelect.replaceChildren(...content);
        elements.objectSelect.value = editor.selectedKey || '';
    }

    function selectedEntity() {
        return entityList().find(entity => entity.key === editor.selectedKey) || null;
    }

    function renderInspector() {
        const entity = selectedEntity();
        if (!entity) {
            elements.properties.innerHTML = '<p class="hint">Выберите объект на карте или в списке.</p>';
            elements.remove.disabled = true;
            elements.remove.textContent = 'Удалить объект';
            return;
        }

        elements.properties.replaceChildren();
        const kind = document.createElement('p');
        kind.className = 'editor-object-kind';
        kind.textContent = entity.title;
        elements.properties.append(kind);

        const coordinates = document.createElement('div');
        coordinates.className = 'editor-property-row';
        coordinates.append(
            propertyInput(entity, { property: 'x', label: 'X', type: 'number', step: 1 }),
            propertyInput(entity, { property: 'y', label: 'Y', type: 'number', step: 1 })
        );
        elements.properties.append(coordinates);

        if (entity.shape === 'rect') {
            const size = document.createElement('div');
            size.className = 'editor-property-row';
            size.append(
                propertyInput(entity, { property: 'width', label: 'Ширина', type: 'number', min: 10, step: 1 }),
                propertyInput(entity, { property: 'height', label: 'Высота', type: 'number', min: 10, step: 1 })
            );
            elements.properties.append(size);
        }

        entity.fields.forEach(field => elements.properties.append(propertyInput(entity, field)));

        const removable = canRemove(entity);
        elements.remove.disabled = !removable;
        elements.remove.textContent = entity.deleteMode === 'pair'
            ? 'Удалить пару ящиков'
            : entity.deleteMode === 'bundle' ? 'Удалить механизм целиком' : 'Удалить объект';
        if (!removable) {
            const note = document.createElement('p');
            note.className = 'hint';
            note.textContent = 'Этот объект обязателен для рабочего уровня или достигнут минимальный лимит.';
            elements.properties.append(note);
        }
    }

    function propertyInput(entity, field) {
        const label = document.createElement('label');
        label.textContent = field.label;
        let input;
        if (field.type === 'select') {
            input = document.createElement('select');
            field.values.forEach((value, index) => {
                const option = document.createElement('option');
                option.value = value;
                option.textContent = field.captions?.[index] || value;
                input.append(option);
            });
        } else {
            input = document.createElement('input');
            input.type = field.type;
            if (field.min !== undefined) input.min = field.min;
            if (field.max !== undefined) input.max = field.max;
            if (field.step !== undefined) input.step = field.step;
        }
        const target = field.target || entity.data;
        input.value = target[field.property];
        input.disabled = Boolean(field.readonly);
        let actionCaptured = false;
        input.addEventListener('focus', () => actionCaptured = false);
        input.addEventListener('input', () => {
            if (!actionCaptured) {
                captureUndoState();
                actionCaptured = true;
            }
            let value = input.value;
            const previousValue = target[field.property];
            if (field.type === 'number') {
                value = Number(value);
                if (!Number.isFinite(value)) return;
                if (field.min !== undefined) value = Math.max(field.min, value);
                if (field.max !== undefined) value = Math.min(field.max, value);
                if (Number(field.step) === 1) value = Math.round(value);
            } else if (field.values?.every(option => typeof option === 'number')) {
                value = Number(value);
            } else if (field.values?.every(option => typeof option === 'boolean')) {
                value = value === 'true';
            }
            target[field.property] = value;
            if (field.triggerName) renameTriggerReferences(previousValue, value);
            clampEntity(entity);
            markDirty();
            drawMap();
            renderObjectSelector();
        });
        input.addEventListener('blur', () => actionCaptured = false);
        label.append(input);
        return label;
    }

    function canRemove(entity) {
        if (entity.bundleCollection) return entity.bundleCollection.length > entity.minimum;
        if (!entity.collection) return false;
        if (entity.deleteMode === 'pair') return entity.collection.length > entity.minimum;
        return entity.collection.length > entity.minimum;
    }

    function removeSelected() {
        const entity = selectedEntity();
        if (!entity || !canRemove(entity)) return;
        const collection = entity.bundleCollection || entity.collection;
        const data = entity.bundleCollection ? entity.bundle : entity.data;
        const index = collection.indexOf(data);
        if (index < 0) return;
        captureUndoState();
        const removedTriggerNames = triggerNamesFromRoot(entity.bundle || data);

        if (entity.deleteMode === 'pair') {
            const otherIndex = nearestOtherIndex(collection, index);
            [index, otherIndex].sort((a, b) => b - a).forEach(removeIndex => {
                if (removeIndex >= 0) collection.splice(removeIndex, 1);
            });
        } else {
            collection.splice(index, 1);
            if (entity.deleteMode === 'bundle' && entity.bundleCollection === editor.map.checkpoints) {
                editor.map.intelTerminals = editor.map.intelTerminals
                    .filter(terminal => terminal.checkpointId !== entity.bundle.id);
            }
        }
        resetRemovedTriggerReferences(removedTriggerNames);
        editor.selectedKey = null;
        markDirty();
        renderEditor();
    }

    function nearestOtherIndex(collection, sourceIndex) {
        const source = collection[sourceIndex];
        let result = -1;
        let distance = Number.POSITIVE_INFINITY;
        collection.forEach((candidate, index) => {
            if (index === sourceIndex) return;
            const current = Math.hypot(candidate.x - source.x, candidate.y - source.y);
            if (current < distance) {
                distance = current;
                result = index;
            }
        });
        return result;
    }

    function addElement() {
        if (!editor.map) return;
        const type = elements.addType.value;
        const center = viewportCenter();
        captureUndoState();
        let created = null;
        switch (type) {
            case 'obstacle':
                created = { x: center.x - 50, y: center.y - 40, width: 100, height: 80 };
                editor.map.obstacles.push(created);
                break;
            case 'label':
                created = { text: 'НОВАЯ ЗОНА', x: center.x, y: center.y };
                editor.map.labels.push(created);
                break;
            case 'trigger-area': {
                const id = uniqueId('trigger-area', editor.map.triggerAreas);
                const area = {
                    id,
                    area: { x: center.x - 70, y: center.y - 70, width: 140, height: 140 },
                    trigger: uniqueTriggerName(`${id}-entered`)
                };
                editor.map.triggerAreas.push(area);
                created = area.area;
                break;
            }
            case 'cooperation-2':
            case 'cooperation-3':
            case 'cooperation-4': {
                const requiredPlayers = Number(type.at(-1));
                const id = uniqueId('cooperation', editor.map.cooperationGates);
                const bundle = {
                    id,
                    gate: mechanismGate(center),
                    plates: distributedPoints(center.x - 90, center.y, requiredPlayers, 64),
                    requiredPlayers,
                    adaptiveToTeamSize: false,
                    triggers: createTriggers(id,
                        [...Array.from({ length: requiredPlayers }, (_, index) => `plate-${index + 1}`), 'opened'])
                };
                editor.map.cooperationGates.push(bundle);
                created = bundle.gate;
                break;
            }
            case 'trust-pocket': {
                const id = uniqueId('trust-pocket', editor.map.trustPockets);
                const bundle = {
                    id,
                    plate: { x: center.x - 90, y: center.y },
                    gate: mechanismGate(center),
                    pocket: { x: center.x + 30, y: center.y - 90, width: 150, height: 180 },
                    triggers: createTriggers(id, ['plate-pressed', 'plate-released'])
                };
                editor.map.trustPockets.push(bundle);
                created = bundle.gate;
                break;
            }
            case 'service-bridge': {
                const id = uniqueId('service-bridge', editor.map.serviceBridges);
                const bundle = {
                    id,
                    plate: { x: center.x - 120, y: center.y },
                    hazard: { x: center.x - 40, y: center.y - 90, width: 200, height: 180 },
                    overrideConsole: { x: center.x + 205, y: center.y },
                    triggers: createTriggers(id, ['plate-pressed', 'override-pressed'])
                };
                editor.map.serviceBridges.push(bundle);
                created = bundle.hazard;
                break;
            }
            case 'separation-gate': {
                const id = uniqueId('separation-gate', editor.map.separationGates);
                const bundle = {
                    id,
                    gate: mechanismGate(center),
                    controls: [{ x: center.x - 100, y: center.y - 65 }, { x: center.x + 100, y: center.y + 65 }],
                    triggers: createTriggers(id, ['control-1', 'control-2'])
                };
                editor.map.separationGates.push(bundle);
                created = bundle.gate;
                break;
            }
            case 'final-relay': {
                const id = uniqueId('final-relay', editor.map.finalRelays);
                const bundle = {
                    id,
                    gate: mechanismGate(center),
                    nodes: [{ x: center.x - 100, y: center.y - 65 }, { x: center.x - 100, y: center.y + 65 }],
                    triggers: createTriggers(id, ['node-1', 'node-2', 'opened'])
                };
                editor.map.finalRelays.push(bundle);
                created = bundle.gate;
                break;
            }
            case 'checkpoint': {
                const id = uniqueId('checkpoint', editor.map.checkpoints);
                const bundle = {
                    id,
                    platforms: distributedPoints(center.x - 90, center.y, 4, 65),
                    exitGate: { x: center.x + 100, y: center.y - 100, width: 24, height: 200 },
                    maximumSurvivors: 4,
                    triggers: createTriggers(id, [
                        'platform-1', 'platform-2', 'platform-3', 'platform-4',
                        'activated', 'cleared', 'failed'
                    ])
                };
                editor.map.checkpoints.push(bundle);
                editor.map.checkpoints.sort((left, right) => left.exitGate.x - right.exitGate.x);
                created = bundle.exitGate;
                break;
            }
            case 'weapon':
                created = {
                    id: uniqueId('firearm', editor.map.weaponPickups),
                    x: center.x,
                    y: center.y,
                    ammo: 5
                };
                editor.map.weaponPickups.push(created);
                break;
            case 'health-boost':
                created = { x: center.x, y: center.y };
                editor.map.healthBoostPickups.push(created);
                break;
            case 'loot': {
                created = { x: center.x, y: center.y };
                editor.map.lootCrates.push(created);
                break;
            }
            case 'intel': {
                const checkpoint = nearestCheckpoint(center.x);
                created = {
                    id: uniqueId('intel', editor.map.intelTerminals),
                    x: center.x,
                    y: center.y,
                    checkpoint: editor.map.checkpoints.indexOf(checkpoint) + 1,
                    checkpointId: checkpoint.id
                };
                editor.map.intelTerminals.push(created);
                break;
            }
            case 'mob-melee':
            case 'mob-ranged':
            case 'mob-assault':
            case 'mob-grenadier':
            case 'boss-assault':
            case 'boss-grenadier': {
                const mobTypes = {
                    'mob-melee': ['crawler', 'MELEE'],
                    'mob-ranged': ['gunner', 'RANGED'],
                    'mob-assault': ['rifleman', 'ASSAULT'],
                    'mob-grenadier': ['grenadier', 'GRENADIER'],
                    'boss-assault': ['boss-assault', 'BOSS_ASSAULT'],
                    'boss-grenadier': ['boss-grenadier', 'BOSS_GRENADIER']
                };
                const [prefix, mobType] = mobTypes[type];
                const defaults = MOB_DEFAULTS[mobType];
                created = {
                    id: uniqueId(prefix, editor.map.mobs),
                    x: center.x,
                    y: center.y,
                    type: mobType,
                    level: 1,
                    health: defaults.health,
                    ammo: defaults.ammo,
                    spawnTrigger: WORLD_CREATED_TRIGGER,
                    route: {
                        enabled: false,
                        points: [{ x: clamp(center.x + 160, 0, editor.map.worldWidth), y: center.y }],
                        startTrigger: WORLD_CREATED_TRIGGER
                    }
                };
                editor.map.mobs.push(created);
                break;
            }
            default:
                return;
        }
        markDirty();
        const entity = entityList().find(candidate => candidate.data === created);
        editor.selectedKey = entity?.key || null;
        renderEditor();
        focusSelected();
    }

    function mechanismGate(center) {
        return { x: center.x - 12, y: center.y - 100, width: 24, height: 200 };
    }

    function distributedPoints(x, centerY, count, spacing) {
        const startY = centerY - spacing * (count - 1) / 2;
        return Array.from({ length: count }, (_, index) => ({ x, y: startY + index * spacing }));
    }

    function nearestCheckpoint(x) {
        return editor.map.checkpoints.reduce((best, checkpoint) =>
            Math.abs(checkpoint.exitGate.x - x) < Math.abs(best.exitGate.x - x) ? checkpoint : best);
    }

    function uniqueId(prefix, collection) {
        const ids = new Set(collection.map(item => item.id));
        let suffix = 1;
        while (ids.has(`${prefix}-${suffix}`)) suffix++;
        return `${prefix}-${suffix}`;
    }

    function uniqueTriggerName(prefix) {
        const names = new Set(allTriggerNames());
        if (!names.has(prefix)) return prefix;
        let suffix = 2;
        while (names.has(`${prefix}-${suffix}`)) suffix++;
        return `${prefix}-${suffix}`;
    }

    function createTriggers(prefix, actions) {
        const triggers = {};
        actions.forEach(action => {
            triggers[action] = uniqueTriggerName(`${prefix}-${action}`);
        });
        return triggers;
    }

    function viewportCenter() {
        const viewportBounds = elements.viewport.getBoundingClientRect();
        const canvasBounds = elements.canvas.getBoundingClientRect();
        const visibleLeft = Math.max(viewportBounds.left, canvasBounds.left);
        const visibleRight = Math.min(viewportBounds.right, canvasBounds.right);
        const visibleTop = Math.max(viewportBounds.top, canvasBounds.top);
        const visibleBottom = Math.min(viewportBounds.bottom, canvasBounds.bottom);
        const centerClientX = (visibleLeft + visibleRight) / 2;
        const centerClientY = (visibleTop + visibleBottom) / 2;
        return {
            x: snap(clamp((centerClientX - canvasBounds.left) * elements.canvas.width / canvasBounds.width,
                20, editor.map.worldWidth - 20)),
            y: snap(clamp((centerClientY - canvasBounds.top) * elements.canvas.height / canvasBounds.height,
                20, editor.map.worldHeight - 20))
        };
    }

    function drawMap() {
        if (!editor.map) return;
        context.clearRect(0, 0, elements.canvas.width, elements.canvas.height);
        context.fillStyle = '#0d1312';
        context.fillRect(0, 0, editor.map.worldWidth, editor.map.worldHeight);
        drawGrid();
        drawTunnelBounds();
        drawBundleLinks();

        const entities = entityList();
        entities.filter(entity => entity.shape === 'rect').forEach(drawEntity);
        entities.filter(entity => entity.shape === 'point' && entity.visual !== 'label').forEach(drawEntity);
        entities.filter(entity => entity.visual === 'label').forEach(drawEntity);

        const selected = selectedEntity();
        if (selected) drawSelection(selected);
    }

    function drawBundleLinks() {
        const link = (anchor, points, color) => {
            const from = anchor.width === undefined ? anchor
                : { x: anchor.x + anchor.width / 2, y: anchor.y + anchor.height / 2 };
            context.save();
            context.strokeStyle = color;
            context.lineWidth = 1.5 / editor.zoom;
            context.setLineDash([8 / editor.zoom, 7 / editor.zoom]);
            points.forEach(point => {
                context.beginPath();
                context.moveTo(from.x, from.y);
                context.lineTo(point.x, point.y);
                context.stroke();
            });
            context.restore();
        };
        editor.map.cooperationGates.forEach(bundle => link(bundle.gate, bundle.plates, 'rgba(255, 222, 134, .45)'));
        editor.map.trustPockets.forEach(bundle => link(bundle.gate, [bundle.plate], 'rgba(255, 222, 134, .45)'));
        editor.map.serviceBridges.forEach(bundle => link(bundle.hazard,
            [bundle.plate, bundle.overrideConsole], 'rgba(110, 224, 237, .45)'));
        editor.map.separationGates.forEach(bundle => link(bundle.gate, bundle.controls, 'rgba(255, 182, 145, .45)'));
        editor.map.finalRelays.forEach(bundle => link(bundle.gate, bundle.nodes, 'rgba(189, 233, 255, .45)'));
        editor.map.checkpoints.forEach(bundle => link(bundle.exitGate, bundle.platforms, 'rgba(255, 154, 142, .35)'));
        editor.map.mobs.filter(mob => mob.route.enabled)
            .forEach(mob => link(mob, mob.route.points, 'rgba(177, 135, 255, .72)'));
    }

    function drawGrid() {
        context.save();
        context.strokeStyle = '#1a2420';
        context.lineWidth = 1 / editor.zoom;
        for (let x = 0; x <= editor.map.worldWidth; x += 100) {
            context.beginPath();
            context.moveTo(x, 0);
            context.lineTo(x, editor.map.worldHeight);
            context.stroke();
        }
        for (let y = 0; y <= editor.map.worldHeight; y += 50) {
            context.beginPath();
            context.moveTo(0, y);
            context.lineTo(editor.map.worldWidth, y);
            context.stroke();
        }
        context.restore();
    }

    function drawTunnelBounds() {
        context.fillStyle = '#202a26';
        context.fillRect(0, 0, editor.map.worldWidth, 70);
        context.fillRect(0, editor.map.worldHeight - 70, editor.map.worldWidth, 70);
        context.fillStyle = '#536158';
        context.fillRect(0, 68, editor.map.worldWidth, 3);
        context.fillRect(0, editor.map.worldHeight - 71, editor.map.worldWidth, 3);
    }

    function drawEntity(entity) {
        if (entity.shape === 'rect') {
            drawRectangleEntity(entity);
        } else {
            drawPointEntity(entity);
        }
    }

    function drawRectangleEntity(entity) {
        const { x, y, width, height } = entity.data;
        const colors = {
            obstacle: ['#354139', '#718078'],
            gate: ['#6b3832', '#cf7568'],
            'checkpoint-gate': ['#70443d', '#ff9586'],
            electric: ['rgba(55, 124, 142, 0.55)', '#78e0ed'],
            fire: ['rgba(151, 58, 32, 0.45)', '#ff805d'],
            'trigger-area': ['rgba(104, 74, 157, 0.25)', '#b78cff']
        };
        const [fill, stroke] = colors[entity.visual] || colors.obstacle;
        context.save();
        context.fillStyle = fill;
        context.fillRect(x, y, width, height);
        context.strokeStyle = stroke;
        context.lineWidth = 2 / editor.zoom;
        context.strokeRect(x, y, width, height);
        if (entity.visual === 'electric' || entity.visual === 'fire' || entity.visual === 'trigger-area') {
            context.beginPath();
            const spacing = 22 / editor.zoom;
            for (let offset = -height; offset < width; offset += spacing) {
                context.moveTo(x + offset, y + height);
                context.lineTo(x + offset + height, y);
            }
            context.globalAlpha = 0.42;
            context.stroke();
        }
        context.restore();
    }

    function drawPointEntity(entity) {
        const { x, y } = entity.data;
        const radius = Math.max(entity.radius, 6 / editor.zoom);
        context.save();
        context.lineWidth = 2 / editor.zoom;
        context.textAlign = 'center';
        context.textBaseline = 'middle';
        context.font = `800 ${Math.max(9, 8 / editor.zoom)}px system-ui`;

        if (entity.visual === 'label') {
            context.textAlign = 'left';
            context.fillStyle = '#aebbb4';
            context.font = `700 ${Math.max(11, 10 / editor.zoom)}px system-ui`;
            context.fillText(entity.data.text, x, y);
            context.restore();
            return;
        }

        if (entity.visual === 'spawn') {
            context.translate(x, y);
            context.rotate(Math.PI / 4);
            context.fillStyle = '#47766f';
            context.strokeStyle = '#9ceadd';
            context.fillRect(-radius * 0.65, -radius * 0.65, radius * 1.3, radius * 1.3);
            context.strokeRect(-radius * 0.65, -radius * 0.65, radius * 1.3, radius * 1.3);
            context.restore();
            return;
        }

        if (entity.visual === 'health-boost') {
            context.fillStyle = '#3d8255';
            context.strokeStyle = '#b8ffc9';
            context.fillRect(x - radius * 0.78, y - radius * 0.78, radius * 1.56, radius * 1.56);
            context.strokeRect(x - radius * 0.78, y - radius * 0.78, radius * 1.56, radius * 1.56);
            context.fillStyle = '#ffffff';
            context.fillText('+50', x, y);
            context.restore();
            return;
        }

        if (entity.visual === 'console' || entity.visual === 'intel' || entity.visual === 'loot'
                || entity.visual === 'weapon') {
            const fills = { console: '#547c52', intel: '#7659a6', loot: '#7a603c', weapon: '#9a8350' };
            context.fillStyle = fills[entity.visual];
            context.strokeStyle = entity.visual === 'intel' ? '#d9c6ff' : '#e5d39f';
            if (entity.visual === 'weapon') {
                context.fillRect(x - radius, y - radius * 0.35, radius * 2, radius * 0.7);
                context.strokeRect(x - radius, y - radius * 0.35, radius * 2, radius * 0.7);
            } else {
                context.fillRect(x - radius * 0.72, y - radius * 0.72, radius * 1.44, radius * 1.44);
                context.strokeRect(x - radius * 0.72, y - radius * 0.72, radius * 1.44, radius * 1.44);
            }
            context.fillStyle = '#ffffff';
            context.fillText({ console: 'E', intel: 'D', loot: 'loot', weapon: 'G' }[entity.visual], x, y);
            context.restore();
            return;
        }

        const styles = {
            plate: ['rgba(198, 162, 68, 0.48)', '#ffe7a0', 'P'],
            relay: ['rgba(80, 143, 176, 0.55)', '#bde9ff', 'R'],
            checkpoint: ['rgba(145, 69, 61, 0.54)', '#ff9a8e', 'О'],
            'route-target': ['rgba(112, 79, 166, 0.66)', '#d5baff', 'Ф'],
            'mob-melee': ['rgba(145, 53, 48, 0.75)', '#ff9a8e', 'M'],
            'mob-ranged': ['rgba(133, 58, 105, 0.8)', '#ffb9df', 'R'],
            'mob-assault': ['rgba(111, 83, 40, 0.85)', '#ffd786', 'A'],
            'mob-grenadier': ['rgba(72, 95, 54, 0.9)', '#c7efa2', 'G'],
            'boss-assault': ['rgba(45, 91, 150, 0.88)', '#9dccff', 'BA'],
            'boss-grenadier': ['rgba(45, 91, 150, 0.88)', '#9dccff', 'BG']
        };
        let [fill, stroke, text] = styles[entity.visual] || styles.plate;
        if (entity.visual.startsWith('mob-') || entity.visual.startsWith('boss-')) {
            fill = entity.data.level === 2 ? 'rgba(154, 52, 45, 0.88)' : 'rgba(45, 91, 150, 0.88)';
            stroke = entity.data.level === 2 ? '#ff9a8e' : '#9dccff';
            text = `${text}${entity.data.level}`;
        }
        context.beginPath();
        if (entity.visual === 'boss-assault') {
            context.rect(x - radius, y - radius, radius * 2, radius * 2);
        } else {
            context.arc(x, y, radius, 0, Math.PI * 2);
        }
        context.fillStyle = fill;
        context.fill();
        context.strokeStyle = stroke;
        context.stroke();
        context.fillStyle = '#ffffff';
        context.fillText(text, x, y);
        context.restore();
    }

    function drawSelection(entity) {
        context.save();
        context.strokeStyle = '#ffffff';
        context.fillStyle = '#ffffff';
        context.lineWidth = 2.5 / editor.zoom;
        context.setLineDash([10 / editor.zoom, 6 / editor.zoom]);
        if (entity.shape === 'rect') {
            const padding = 5 / editor.zoom;
            context.strokeRect(
                entity.data.x - padding,
                entity.data.y - padding,
                entity.data.width + padding * 2,
                entity.data.height + padding * 2
            );
            context.setLineDash([]);
            const handle = 11 / editor.zoom;
            context.fillRect(
                entity.data.x + entity.data.width - handle / 2,
                entity.data.y + entity.data.height - handle / 2,
                handle,
                handle
            );
        } else {
            const radius = Math.max(entity.radius, 10 / editor.zoom) + 6 / editor.zoom;
            context.beginPath();
            context.arc(entity.data.x, entity.data.y, radius, 0, Math.PI * 2);
            context.stroke();
        }
        context.setLineDash([]);
        const position = entityPosition(entity);
        context.fillStyle = 'rgba(5, 9, 8, 0.92)';
        context.font = `700 ${12 / editor.zoom}px system-ui`;
        const width = context.measureText(entity.title).width + 16 / editor.zoom;
        const height = 24 / editor.zoom;
        context.fillRect(position.x - width / 2, position.y - 42 / editor.zoom, width, height);
        context.fillStyle = '#ffffff';
        context.textAlign = 'center';
        context.textBaseline = 'middle';
        context.fillText(entity.title, position.x, position.y - 30 / editor.zoom);
        context.restore();
    }

    function canvasPoint(event) {
        const bounds = elements.canvas.getBoundingClientRect();
        return {
            x: (event.clientX - bounds.left) * elements.canvas.width / bounds.width,
            y: (event.clientY - bounds.top) * elements.canvas.height / bounds.height
        };
    }

    function hitEntity(point) {
        const entities = entityList();
        for (let index = entities.length - 1; index >= 0; index--) {
            const entity = entities[index];
            if (entity.shape === 'rect') {
                if (point.x >= entity.data.x && point.x <= entity.data.x + entity.data.width
                        && point.y >= entity.data.y && point.y <= entity.data.y + entity.data.height) {
                    return entity;
                }
            } else if (entity.visual === 'label') {
                const width = Math.max(80, String(entity.data.text).length * 10);
                if (point.x >= entity.data.x && point.x <= entity.data.x + width
                        && point.y >= entity.data.y - 18 && point.y <= entity.data.y + 6) {
                    return entity;
                }
            } else if (Math.hypot(point.x - entity.data.x, point.y - entity.data.y)
                    <= Math.max(entity.radius, 11 / editor.zoom)) {
                return entity;
            }
        }
        return null;
    }

    function onPointerDown(event) {
        if (!editor.map || event.button !== 0) return;
        const point = canvasPoint(event);
        const selected = selectedEntity();
        if (selected?.shape === 'rect' && onResizeHandle(selected, point)) {
            editor.drag = { mode: 'resize', key: selected.key, undoCaptured: false, changed: false };
        } else {
            const hit = hitEntity(point);
            editor.selectedKey = hit?.key || null;
            if (hit) {
                editor.drag = {
                    mode: 'move',
                    key: hit.key,
                    offsetX: point.x - hit.data.x,
                    offsetY: point.y - hit.data.y,
                    undoCaptured: false,
                    changed: false
                };
            } else {
                editor.drag = null;
            }
        }
        elements.canvas.setPointerCapture(event.pointerId);
        renderObjectSelector();
        renderInspector();
        drawMap();
    }

    function onPointerMove(event) {
        if (!editor.drag) return;
        const entity = entityList().find(candidate => candidate.key === editor.drag.key);
        if (!entity) return;
        const point = canvasPoint(event);
        if (!editor.drag.undoCaptured) {
            captureUndoState();
            editor.drag.undoCaptured = true;
        }
        if (editor.drag.mode === 'resize' && entity.shape === 'rect') {
            entity.data.width = snap(clamp(point.x - entity.data.x, 10, editor.map.worldWidth - entity.data.x));
            entity.data.height = snap(clamp(point.y - entity.data.y, 10, editor.map.worldHeight - entity.data.y));
        } else {
            entity.data.x = snap(point.x - editor.drag.offsetX);
            entity.data.y = snap(point.y - editor.drag.offsetY);
            clampEntity(entity);
        }
        editor.drag.changed = true;
        markDirty();
        renderInspector();
        drawMap();
    }

    function onPointerUp(event) {
        if (editor.drag?.changed) markDirty();
        editor.drag = null;
        if (elements.canvas.hasPointerCapture(event.pointerId)) {
            elements.canvas.releasePointerCapture(event.pointerId);
        }
    }

    function onResizeHandle(entity, point) {
        const tolerance = 14 / editor.zoom;
        return Math.abs(point.x - (entity.data.x + entity.data.width)) <= tolerance
            && Math.abs(point.y - (entity.data.y + entity.data.height)) <= tolerance;
    }

    function clampEntity(entity) {
        if (entity.shape === 'rect') {
            entity.data.width = clamp(Number(entity.data.width), 10, editor.map.worldWidth);
            entity.data.height = clamp(Number(entity.data.height), 10, editor.map.worldHeight);
            entity.data.x = clamp(Number(entity.data.x), 0, editor.map.worldWidth - entity.data.width);
            entity.data.y = clamp(Number(entity.data.y), 0, editor.map.worldHeight - entity.data.height);
        } else {
            entity.data.x = clamp(Number(entity.data.x), 0, editor.map.worldWidth);
            entity.data.y = clamp(Number(entity.data.y), 0, editor.map.worldHeight);
        }
    }

    function snap(value) {
        return elements.gridSnap.checked ? Math.round(value / 10) * 10 : Math.round(value);
    }

    function entityPosition(entity) {
        return entity.shape === 'rect'
            ? { x: entity.data.x + entity.data.width / 2, y: entity.data.y + entity.data.height / 2 }
            : { x: entity.data.x, y: entity.data.y };
    }

    function focusSelected() {
        const entity = selectedEntity();
        if (!entity) return;
        const position = entityPosition(entity);
        elements.viewport.scrollTo({
            left: Math.max(0, position.x * editor.zoom - elements.viewport.clientWidth / 2 + elements.canvas.offsetLeft),
            top: Math.max(0, position.y * editor.zoom - elements.viewport.clientHeight / 2 + elements.canvas.offsetTop),
            behavior: 'smooth'
        });
    }

    function markDirty() {
        editor.dirty = JSON.stringify(editor.map) !== editor.savedState;
        setStatus(editor.dirty ? 'Есть изменения, не сохранённые на сервере.' : 'Все изменения сохранены на сервере.', false, editor.dirty);
        clearTimeout(editor.draftTimer);
        editor.draftTimer = setTimeout(persistDraft, 250);
    }

    function captureUndoState() {
        if (!editor.map) return;
        const serialized = JSON.stringify(editor.map);
        if (editor.history.at(-1)?.serialized === serialized) return;
        editor.history.push({ serialized, map: deepCopy(editor.map) });
        if (editor.history.length > 10) editor.history.shift();
        updateUndoButton();
    }

    function undo() {
        if (!editor.map || editor.history.length === 0) return;
        const previous = editor.history.pop();
        const selectedKey = editor.selectedKey;
        editor.map = normalizeMap(previous.map);
        editor.selectedKey = entityList().some(entity => entity.key === selectedKey) ? selectedKey : null;
        editor.drag = null;
        elements.mapId.disabled = !editor.isNew;
        resizeCanvas();
        renderEditor();
        markDirty();
        updateUndoButton();
        setStatus(editor.dirty
            ? `Действие отменено. В истории осталось: ${editor.history.length}.`
            : 'Действие отменено. Карта вернулась к сохранённому состоянию.', false, editor.dirty);
    }

    function updateUndoButton() {
        elements.undo.disabled = editor.history.length === 0;
        elements.undo.textContent = editor.history.length > 0
            ? `Отменить · Ctrl+Z (${editor.history.length})`
            : 'Отменить · Ctrl+Z';
    }

    function setStatus(message, error = false, dirty = false) {
        elements.status.textContent = message;
        elements.status.classList.toggle('error', error);
        elements.status.classList.toggle('dirty', dirty);
        elements.save.textContent = editor.saving ? 'Сохранение…'
            : error ? 'Повторить сохранение' : editor.dirty ? 'Сохранить карту *' : 'Сохранить карту';
    }

    function drafts() {
        try {
            return Object.keys(localStorage).filter(key => key.startsWith(DRAFT_PREFIX))
                .map(key => { try { return { ...JSON.parse(localStorage.getItem(key)), key }; } catch { return null; } })
                .filter(value => value?.map).sort((a, b) => b.updatedAt - a.updatedAt);
        } catch { return []; }
    }

    function persistDraft() {
        if (!editor.map || !editor.draftKey) return;
        try {
            if (!editor.dirty && !editor.saving) { localStorage.removeItem(editor.draftKey); return; }
            localStorage.setItem(editor.draftKey, JSON.stringify({
                map: editor.map, loadedId: editor.loadedId, isNew: editor.isNew,
                savedState: editor.savedState, revision: editor.revision, updatedAt: Date.now()
            }));
        } catch {
            setStatus('Браузер не смог записать черновик. Скачайте .map или сохраните карту на сервер перед закрытием.', true);
        }
    }

    function restoreDraft(draft) {
        loadIntoEditor(deepCopy(draft.map), draft.isNew, draft.loadedId, null, draft.revision);
        editor.savedState = draft.savedState;
        editor.draftKey = draft.key || editor.draftKey;
        markDirty();
        setStatus('Черновик восстановлен из браузера. Нажмите «Сохранить», чтобы отправить его на сервер.', false, true);
    }

    function exportMap() {
        if (!editor.map) return;
        const url = URL.createObjectURL(new Blob([JSON.stringify(editor.map, null, 2)], { type: 'application/json' }));
        const link = document.createElement('a');
        link.href = url;
        link.download = `${/^[a-z0-9-]+$/.test(editor.map.id) ? editor.map.id : 'map-draft'}.map`;
        link.click();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
    }

    function canonical(value) {
        if (Array.isArray(value)) return value.map(canonical);
        if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
        return value;
    }

    function minimumRequiredWidth() {
        return Math.ceil(entityList().reduce((maximum, entity) => {
            const right = entity.shape === 'rect'
                ? entity.data.x + entity.data.width
                : entity.data.x;
            return Math.max(maximum, right);
        }, 960));
    }

    function minimumRequiredHeight() {
        return Math.ceil(entityList().reduce((maximum, entity) => {
            const bottom = entity.shape === 'rect'
                ? entity.data.y + entity.data.height
                : entity.data.y;
            return Math.max(maximum, bottom);
        }, 540));
    }

    async function saveMap() {
        if (!editor.map || editor.saving) return;
        // Commit a numeric input's change event before capturing the submitted state.
        document.activeElement?.blur();
        editor.map.id = elements.mapId.value.trim();
        editor.map.name = elements.mapName.value.trim();
        const validationError = validateMap();
        if (validationError) {
            setStatus(validationError, true);
            persistDraft();
            return;
        }

        const submitted = JSON.stringify(editor.map);
        const wasNew = editor.isNew;
        const submittedRevision = editor.revision;
        editor.saving = true;
        persistDraft();
        elements.save.disabled = true;
        elements.back.disabled = true;
        elements.mapId.disabled = true;
        setStatus('Сохранение карты…');
        try {
            const path = editor.isNew
                ? '/api/editor/maps'
                : `/api/editor/maps/${encodeURIComponent(editor.loadedId)}`;
            let result;
            try {
                result = await request(path, {
                    method: wasNew ? 'POST' : 'PUT', body: submitted, withMeta: true,
                    headers: !wasNew && submittedRevision ? { 'If-Match': submittedRevision } : {}
                });
            } catch (error) {
                // An earlier request may have committed but lost its response. Confirm
                // the exact submitted content; never overwrite a different saved version.
                if (![409, 412].includes(error.status)) throw error;
                result = await request(`/api/editor/maps/${encodeURIComponent(editor.map.id)}`, { withMeta: true });
                if (JSON.stringify(canonical(normalizeMap(deepCopy(result.map))))
                        !== JSON.stringify(canonical(normalizeMap(JSON.parse(submitted))))) throw error;
            }
            const saved = result.map;
            const unchanged = JSON.stringify(editor.map) === submitted;
            const normalized = normalizeMap(deepCopy(saved));
            if (unchanged) editor.map = normalized;
            editor.loadedId = saved.id;
            editor.isNew = false;
            editor.revision = result.revision;
            editor.savedState = JSON.stringify(normalized);
            editor.dirty = JSON.stringify(editor.map) !== editor.savedState;
            if (unchanged) editor.history = [];
            updateUndoButton();
            elements.mapId.disabled = true;
            // Inspector event handlers capture object references. Rebind after replacing
            // the map, or subsequent property edits silently modify the old object graph.
            if (unchanged) renderEditor();
            setStatus(editor.dirty
                ? 'Отправленная версия сохранена. Новые правки ещё не сохранены — нажмите «Сохранить» снова.'
                : `Карта «${saved.name}» сохранена на сервере в ${new Date().toLocaleTimeString()}.`, false, editor.dirty);
        } catch (error) {
            setStatus(error.message, true);
        } finally {
            editor.saving = false;
            elements.save.disabled = false;
            elements.back.disabled = false;
            elements.mapId.disabled = !editor.isNew;
            elements.save.textContent = editor.dirty ? 'Сохранить карту *' : 'Сохранить карту';
            persistDraft();
        }
    }

    function validateMap() {
        const map = editor.map;
        if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(map.id)) {
            return 'ID: только строчные латинские буквы, цифры и дефисы, максимум 40 символов.';
        }
        if (!map.name) return 'Введите название карты.';
        if (map.worldWidth < 960 || map.worldWidth > 20000
                || map.worldHeight < 540 || map.worldHeight > 2000) {
            return 'Длина туннеля должна быть 960–20000, высота — 540–2000.';
        }
        if (map.playerSpawns.length !== 4 || map.checkpoints.length < 1 || map.checkpoints.length > 8) {
            return 'Карта должна содержать четыре старта игроков и от одной до восьми отсечек.';
        }
        if (map.cooperationGates.some(gate => gate.requiredPlayers < 2 || gate.requiredPlayers > 4
                || gate.plates.length !== gate.requiredPlayers)
                || map.separationGates.some(gate => gate.controls.length < 1)
                || map.finalRelays.some(relay => relay.nodes.length !== 2)
                || map.checkpoints.some(checkpoint => checkpoint.platforms.length < 4
                    || checkpoint.maximumSurvivors < 1 || checkpoint.maximumSurvivors > 4)) {
            return 'Проверьте число связанных плит/кнопок и лимит выживших у шлюзов и отсечек.';
        }
        for (const collection of [map.weaponPickups, map.intelTerminals, map.mobs,
            map.cooperationGates, map.trustPockets, map.serviceBridges,
            map.separationGates, map.finalRelays, map.checkpoints, map.triggerAreas]) {
            const ids = collection.map(item => item.id);
            if (ids.some(id => !id) || new Set(ids).size !== ids.length) {
                return 'У объектов и связок должны быть непустые уникальные ID внутри своего типа.';
            }
        }
        if (map.labels.some(label => !String(label.text || '').trim())) {
            return 'У каждой подписи зоны должен быть текст.';
        }
        if (map.weaponPickups.some(weapon => !Number.isInteger(weapon.ammo) || weapon.ammo < 1)) {
            return 'Количество патронов в каждом огнестреле должно быть положительным целым числом.';
        }
        const checkpointIds = new Set(map.checkpoints.map(checkpoint => checkpoint.id));
        if (map.intelTerminals.some(terminal => !checkpointIds.has(terminal.checkpointId))) {
            return 'Каждый терминал данных должен ссылаться на существующую отсечку.';
        }
        if (map.mobs.some(mob => !['MELEE', 'RANGED', 'ASSAULT', 'GRENADIER',
            'BOSS_ASSAULT', 'BOSS_GRENADIER'].includes(mob.type))) {
            return 'У каждого моба должен быть выбран тип боя.';
        }
        if (map.mobs.some(mob => !Number.isInteger(mob.health) || mob.health < 1 || mob.health > 5000
                || !Number.isInteger(mob.ammo) || mob.ammo < 0 || mob.ammo > 10000)) {
            return 'HP моба: 1–5000. Боезапас: 0–10000. Оба значения должны быть целыми.';
        }
        if (map.mobs.some(mob => ![1, 2].includes(mob.level))) {
            return 'Уровень поведения моба должен быть равен 1 или 2.';
        }
        const triggerNames = allTriggerNames();
        if (triggerNames.some(name => !/^[a-z0-9][a-z0-9-]{0,63}$/.test(name))) {
            return 'Имя триггера: только строчные латинские буквы, цифры и дефисы, максимум 64 символа.';
        }
        if (new Set(triggerNames).size !== triggerNames.length) {
            return 'Имена триггеров должны быть уникальными внутри карты.';
        }
        const knownTriggers = new Set(triggerNames);
        if (map.mobs.some(mob => !knownTriggers.has(mob.spawnTrigger)
                || !knownTriggers.has(mob.route.startTrigger))) {
            return 'Триггер появления и маршрута каждого моба должен существовать на карте.';
        }
        if (map.mobs.some(mob => typeof mob.route.enabled !== 'boolean'
                || mob.route.points.length !== 1)) {
            return 'Маршрут моба сейчас должен содержать ровно одну финальную точку.';
        }
        const outside = entityList().find(entity => entity.shape === 'rect'
            ? entity.data.x < 0 || entity.data.y < 0
                || entity.data.x + entity.data.width > map.worldWidth
                || entity.data.y + entity.data.height > map.worldHeight
            : entity.data.x < 0 || entity.data.y < 0
                || entity.data.x > map.worldWidth || entity.data.y > map.worldHeight);
        if (outside) return `Объект «${outside.title}» находится за пределами туннеля.`;
        return null;
    }

    function leaveEditor() {
        if (editor.saving) return;
        persistDraft();
        if (editor.dirty && !window.confirm('Несохранённые изменения будут потеряны. Выйти?')) return;
        editor.map = null;
        editor.selectedKey = null;
        openMapBrowser();
    }

    elements.openEditor.addEventListener('click', () => openMapBrowser());
    elements.browserBack.addEventListener('click', () => showScreen(elements.mainMenu));
    elements.openMap.addEventListener('click', loadExistingMap);
    elements.copyMap.addEventListener('click', createMapCopy);
    elements.newMap.addEventListener('click', createMapFromTemplate);
    elements.emptyMap.addEventListener('click', createEmptyMap);
    elements.back.addEventListener('click', leaveEditor);
    elements.undo.addEventListener('click', undo);
    elements.save.addEventListener('click', saveMap);
    elements.export.addEventListener('click', exportMap);
    elements.restoreDraft.addEventListener('click', () => {
        const draft = drafts()[0];
        if (draft) restoreDraft(draft);
        else setBrowserMessage('В этом браузере нет сохранённых черновиков.');
    });
    elements.add.addEventListener('click', addElement);
    elements.remove.addEventListener('click', removeSelected);

    let mapIdActionCaptured = false;
    elements.mapId.addEventListener('focus', () => mapIdActionCaptured = false);
    elements.mapId.addEventListener('input', () => {
        if (!editor.map || !editor.isNew) return;
        if (!mapIdActionCaptured) {
            captureUndoState();
            mapIdActionCaptured = true;
        }
        editor.map.id = elements.mapId.value.trim();
        markDirty();
    });
    elements.mapId.addEventListener('blur', () => mapIdActionCaptured = false);

    let mapNameActionCaptured = false;
    elements.mapName.addEventListener('focus', () => mapNameActionCaptured = false);
    elements.mapName.addEventListener('input', () => {
        if (!editor.map) return;
        if (!mapNameActionCaptured) {
            captureUndoState();
            mapNameActionCaptured = true;
        }
        editor.map.name = elements.mapName.value;
        markDirty();
    });
    elements.mapName.addEventListener('blur', () => mapNameActionCaptured = false);
    elements.worldWidth.addEventListener('change', () => {
        if (!editor.map) return;
        const requested = clamp(Math.round(Number(elements.worldWidth.value) || 960), 960, 20000);
        const minimum = minimumRequiredWidth();
        if (editor.map.worldWidth !== Math.max(requested, minimum)) captureUndoState();
        editor.map.worldWidth = Math.max(requested, minimum);
        editor.map.mobs.forEach(mob => mob.route.points.forEach(point => {
            point.x = clamp(point.x, 0, editor.map.worldWidth);
        }));
        elements.worldWidth.value = editor.map.worldWidth;
        resizeCanvas();
        markDirty();
        renderEditor();
        if (requested < minimum) {
            setStatus(`Сначала переместите правые объекты: минимальная длина сейчас ${minimum}.`, true);
        }
    });
    elements.worldHeight.addEventListener('change', () => {
        if (!editor.map) return;
        const requested = clamp(Math.round(Number(elements.worldHeight.value) || 540), 540, 2000);
        const minimum = minimumRequiredHeight();
        if (editor.map.worldHeight !== Math.max(requested, minimum)) captureUndoState();
        editor.map.worldHeight = Math.max(requested, minimum);
        editor.map.mobs.forEach(mob => mob.route.points.forEach(point => {
            point.y = clamp(point.y, 0, editor.map.worldHeight);
        }));
        elements.worldHeight.value = editor.map.worldHeight;
        resizeCanvas();
        markDirty();
        renderEditor();
        if (requested < minimum) {
            setStatus(`Сначала переместите нижние объекты: минимальная высота сейчас ${minimum}.`, true);
        }
    });
    elements.zoom.addEventListener('input', () => {
        editor.zoom = Number(elements.zoom.value) / 100;
        resizeCanvas();
        drawMap();
    });
    elements.objectSelect.addEventListener('change', () => {
        editor.selectedKey = elements.objectSelect.value || null;
        renderInspector();
        drawMap();
        focusSelected();
    });

    elements.canvas.addEventListener('pointerdown', onPointerDown);
    elements.canvas.addEventListener('pointermove', onPointerMove);
    elements.canvas.addEventListener('pointerup', onPointerUp);
    elements.canvas.addEventListener('pointercancel', onPointerUp);

    document.addEventListener('keydown', event => {
        if (elements.screen.classList.contains('hidden')) return;
        if ((event.ctrlKey || event.metaKey) && event.code === 'KeyS') {
            event.preventDefault();
            saveMap();
            return;
        }
        if ((event.ctrlKey || event.metaKey) && event.code === 'KeyZ') {
            event.preventDefault();
            if (!event.repeat) undo();
            return;
        }
        const editingField = ['INPUT', 'SELECT', 'TEXTAREA'].includes(document.activeElement?.tagName);
        if (!editingField && (event.code === 'Delete' || event.code === 'Backspace')) {
            event.preventDefault();
            removeSelected();
        }
    });

    window.addEventListener('beforeunload', event => {
        persistDraft();
        if (!editor.dirty) return;
        event.preventDefault();
        event.returnValue = '';
    });
    window.addEventListener('pagehide', persistDraft);
})();
