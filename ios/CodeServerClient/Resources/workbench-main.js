// Adapted from @vscode/test-web (out/browser/esm/main.js), MIT License,
// Copyright (c) Microsoft Corporation. Import rewritten to the bundle path
// served by WorkbenchServer.
import { create, URI, Emitter } from '/static/out/vs/workbench/workbench.web.main.internal.js';
class WorkspaceProvider {
    workspace;
    payload;
    static QUERY_PARAM_EMPTY_WINDOW = 'ew';
    static QUERY_PARAM_FOLDER = 'folder';
    static QUERY_PARAM_WORKSPACE = 'workspace';
    static QUERY_PARAM_PAYLOAD = 'payload';
    static create(config) {
        let foundWorkspace = false;
        let workspace;
        let payload = Object.create(null);
        const query = new URL(document.location.href).searchParams;
        query.forEach((value, key) => {
            switch (key) {
                case WorkspaceProvider.QUERY_PARAM_FOLDER:
                    workspace = { folderUri: URI.parse(value) };
                    foundWorkspace = true;
                    break;
                case WorkspaceProvider.QUERY_PARAM_WORKSPACE:
                    workspace = { workspaceUri: URI.parse(value) };
                    foundWorkspace = true;
                    break;
                case WorkspaceProvider.QUERY_PARAM_EMPTY_WINDOW:
                    workspace = undefined;
                    foundWorkspace = true;
                    break;
                case WorkspaceProvider.QUERY_PARAM_PAYLOAD:
                    try {
                        payload = JSON.parse(value);
                    }
                    catch (error) {
                        console.error(error);
                    }
                    break;
            }
        });
        if (!foundWorkspace) {
            if (config.folderUri) {
                workspace = { folderUri: URI.revive(config.folderUri) };
            }
            else if (config.workspaceUri) {
                workspace = { workspaceUri: URI.revive(config.workspaceUri) };
            }
        }
        return new WorkspaceProvider(workspace, payload);
    }
    trusted = true;
    constructor(workspace, payload) {
        this.workspace = workspace;
        this.payload = payload;
    }
    async open(workspace, options) {
        if (options?.reuse && !options.payload && this.isSame(this.workspace, workspace)) {
            return true;
        }
        const targetHref = this.createTargetUrl(workspace, options);
        if (targetHref) {
            if (options?.reuse) {
                window.location.href = targetHref;
                return true;
            }
            else {
                return !!window.open(targetHref);
            }
        }
        return false;
    }
    createTargetUrl(workspace, options) {
        let targetHref = undefined;
        if (!workspace) {
            targetHref = `${document.location.origin}${document.location.pathname}?${WorkspaceProvider.QUERY_PARAM_EMPTY_WINDOW}=true`;
        }
        else if ('folderUri' in workspace) {
            const queryParamFolder = encodeURIComponent(workspace.folderUri.toString(true));
            targetHref = `${document.location.origin}${document.location.pathname}?${WorkspaceProvider.QUERY_PARAM_FOLDER}=${queryParamFolder}`;
        }
        else if ('workspaceUri' in workspace) {
            const queryParamWorkspace = encodeURIComponent(workspace.workspaceUri.toString(true));
            targetHref = `${document.location.origin}${document.location.pathname}?${WorkspaceProvider.QUERY_PARAM_WORKSPACE}=${queryParamWorkspace}`;
        }
        if (options?.payload) {
            targetHref += `&${WorkspaceProvider.QUERY_PARAM_PAYLOAD}=${encodeURIComponent(JSON.stringify(options.payload))}`;
        }
        return targetHref;
    }
    isSame(workspaceA, workspaceB) {
        if (!workspaceA || !workspaceB) {
            return workspaceA === workspaceB;
        }
        if ('folderUri' in workspaceA && 'folderUri' in workspaceB) {
            return this.isEqualURI(workspaceA.folderUri, workspaceB.folderUri);
        }
        if ('workspaceUri' in workspaceA && 'workspaceUri' in workspaceB) {
            return this.isEqualURI(workspaceA.workspaceUri, workspaceB.workspaceUri);
        }
        return false;
    }
    isEqualURI(a, b) {
        return a.scheme === b.scheme && a.authority === b.authority && a.path === b.path;
    }
}
class LocalStorageURLCallbackProvider {
    _callbackRoute;
    static REQUEST_ID = 0;
    static QUERY_KEYS = [
        'scheme',
        'authority',
        'path',
        'query',
        'fragment'
    ];
    _onCallback = new Emitter();
    onCallback = this._onCallback.event;
    pendingCallbacks = new Set();
    lastTimeChecked = Date.now();
    checkCallbacksTimeout = undefined;
    onDidChangeLocalStorageDisposable;
    constructor(_callbackRoute) {
        this._callbackRoute = _callbackRoute;
    }
    create(options = {}) {
        const id = ++LocalStorageURLCallbackProvider.REQUEST_ID;
        const queryParams = [`vscode-reqid=${id}`];
        for (const key of LocalStorageURLCallbackProvider.QUERY_KEYS) {
            const value = options[key];
            if (value) {
                queryParams.push(`vscode-${key}=${encodeURIComponent(value)}`);
            }
        }
        if (!(options.authority === 'vscode.github-authentication' && options.path === '/dummy')) {
            const key = `vscode-web.url-callbacks[${id}]`;
            localStorage.removeItem(key);
            this.pendingCallbacks.add(id);
            this.startListening();
        }
        return URI.parse(window.location.href).with({ path: this._callbackRoute, query: queryParams.join('&') });
    }
    startListening() {
        if (this.onDidChangeLocalStorageDisposable) {
            return;
        }
        const fn = () => this.onDidChangeLocalStorage();
        window.addEventListener('storage', fn);
        this.onDidChangeLocalStorageDisposable = { dispose: () => window.removeEventListener('storage', fn) };
    }
    stopListening() {
        this.onDidChangeLocalStorageDisposable?.dispose();
        this.onDidChangeLocalStorageDisposable = undefined;
    }
    async onDidChangeLocalStorage() {
        const ellapsed = Date.now() - this.lastTimeChecked;
        if (ellapsed > 1000) {
            this.checkCallbacks();
        }
        else if (this.checkCallbacksTimeout === undefined) {
            this.checkCallbacksTimeout = setTimeout(() => {
                this.checkCallbacksTimeout = undefined;
                this.checkCallbacks();
            }, 1000 - ellapsed);
        }
    }
    checkCallbacks() {
        let pendingCallbacks;
        for (const id of this.pendingCallbacks) {
            const key = `vscode-web.url-callbacks[${id}]`;
            const result = localStorage.getItem(key);
            if (result !== null) {
                try {
                    this._onCallback.fire(URI.revive(JSON.parse(result)));
                }
                catch (error) {
                    console.error(error);
                }
                pendingCallbacks = pendingCallbacks ?? new Set(this.pendingCallbacks);
                pendingCallbacks.delete(id);
                localStorage.removeItem(key);
            }
        }
        if (pendingCallbacks) {
            this.pendingCallbacks = pendingCallbacks;
            if (this.pendingCallbacks.size === 0) {
                this.stopListening();
            }
        }
        this.lastTimeChecked = Date.now();
    }
    dispose() {
        this._onCallback.dispose();
    }
}
// URL-callback provider that routes OAuth through the native layer's
// ASWebAuthenticationSession (real Safari → password AutoFill + Face ID),
// instead of a WKWebView popup. create() points the redirect at the server's
// /auth-bridge route, which 302s to a custom scheme the auth session catches;
// native then calls window.__nativeAuthDeliver with the final query string.
// The reconstruction below mirrors the bundle's callback.html exactly.
class NativeURLCallbackProvider {
    constructor() {
        this._emitter = new Emitter();
        this.onCallback = this._emitter.event;
        this._reqId = 0;
        window.__nativeAuthDeliver = (rawQuery) => this._deliver(rawQuery);
    }
    create(options = {}) {
        // Mark that an OAuth flow is starting; bridge.js routes the imminent
        // window.open to the native auth session (vs the system browser).
        window.__codeAuthExpected = Date.now();
        const id = ++this._reqId;
        const q = [`vscode-reqid=${id}`];
        for (const key of ['scheme', 'authority', 'path', 'query', 'fragment']) {
            if (options[key]) q.push(`vscode-${key}=${encodeURIComponent(options[key])}`);
        }
        return URI.parse(window.location.href).with({ path: '/auth-bridge', query: q.join('&') });
    }
    _deliver(rawQuery) {
        const params = new URLSearchParams(rawQuery);
        const scheme = params.get('vscode-scheme');
        const authority = params.get('vscode-authority');
        if (!scheme || !authority) return;
        const path = params.get('vscode-path');
        const query = params.get('vscode-query');
        const fragment = params.get('vscode-fragment');
        for (const k of ['vscode-reqid', 'vscode-scheme', 'vscode-authority', 'vscode-path', 'vscode-query', 'vscode-fragment']) {
            params.delete(k);
        }
        const uri = { scheme, authority };
        if (path) uri.path = path;
        if (query) { new URLSearchParams(query).forEach((v, k) => params.set(k, v)); }
        const rq = params.toString();
        if (rq) uri.query = rq;
        if (fragment) uri.fragment = fragment;
        this._emitter.fire(URI.from(uri));
    }
}

(function () {
    const configElement = window.document.getElementById('vscode-workbench-web-configuration');
    const configElementAttribute = configElement ? configElement.getAttribute('data-settings') : undefined;
    if (!configElement || !configElementAttribute) {
        throw new Error('Missing web configuration element');
    }
    const config = JSON.parse(configElementAttribute);
    // Use the native auth-session provider when running inside the wrapper;
    // fall back to the localStorage provider otherwise (e.g. plain browser).
    const nativeAuth = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.authSession);
    create(window.document.body, {
        ...config,
        workspaceProvider: WorkspaceProvider.create(config),
        urlCallbackProvider: nativeAuth
            ? new NativeURLCallbackProvider()
            : new LocalStorageURLCallbackProvider(config.callbackRoute)
    });
})();
