Ext.define('pve-env-proxy', {
    extend: 'Ext.data.Model',
    fields: [
        'id',
        'label',
        'type',
        'host',
        'port',
        'username',
        'has-password',
        'provider',
        'region',
        'notes',
        'expires',
        'expired',
        'max-bindings',
        'state',
        'fails',
        'exit-ip',
        'exit-country',
        'exit-region',
        'exit-city',
        'exit-since',
        'last-check',
        'bindings',
        {
            name: 'latency',
            calculate: (data) => data['last-check']?.latency,
        },
        {
            name: 'checked',
            calculate: (data) => data['last-check']?.time,
        },
        {
            name: 'bindcount',
            calculate: (data) => (data.bindings ?? []).length,
        },
    ],
    idProperty: 'id',
});

Ext.define('PVE.dc.EnvProxyEdit', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveEnvProxyEdit',

    subject: gettext('Proxy'),
    width: 560,

    initComponent: function () {
        let me = this;

        me.isCreate = !me.proxyId;
        me.method = me.isCreate ? 'POST' : 'PUT';
        me.url = me.isCreate
            ? '/api2/extjs/cluster/environments/proxies'
            : `/api2/extjs/cluster/environments/proxies/${me.proxyId}`;

        me.items = {
            xtype: 'inputpanel',
            onGetValues: function (values) {
                if (me.isCreate) {
                    for (const [k, v] of Object.entries(values)) {
                        if (v === '' || v === null) {
                            delete values[k];
                        }
                    }
                } else {
                    let del = [];
                    for (const k of ['provider', 'region', 'notes', 'username']) {
                        if (values[k] === '') {
                            delete values[k];
                            del.push(k);
                        }
                    }
                    if (values.password === '') {
                        delete values.password; // unchanged
                    }
                    if (del.length) {
                        values.delete = del.join(',');
                    }
                }
                if (values.expires instanceof Date) {
                    values.expires = Math.floor(values.expires.getTime() / 1000);
                } else if (!me.isCreate && !values.expires) {
                    values.expires = 0;
                } else if (!values.expires) {
                    delete values.expires;
                }
                return values;
            },
            column1: [
                {
                    xtype: 'proxmoxKVComboBox',
                    name: 'type',
                    fieldLabel: gettext('Type'),
                    value: 'http',
                    comboItems: [
                        ['http', 'HTTP'],
                        ['https', 'HTTPS'],
                        ['socks5', 'SOCKS5'],
                    ],
                },
                {
                    xtype: 'textfield',
                    name: 'host',
                    allowBlank: false,
                    fieldLabel: gettext('Host'),
                },
                {
                    xtype: 'proxmoxintegerfield',
                    name: 'port',
                    minValue: 1,
                    maxValue: 65535,
                    allowBlank: false,
                    fieldLabel: gettext('Port'),
                },
                {
                    xtype: 'textfield',
                    name: 'username',
                    fieldLabel: gettext('Username'),
                },
                {
                    xtype: 'proxmoxtextfield',
                    inputType: 'password',
                    name: 'password',
                    fieldLabel: gettext('Password'),
                    emptyText: me.isCreate ? '' : gettext('Unchanged'),
                },
            ],
            column2: [
                {
                    xtype: 'textfield',
                    name: 'provider',
                    fieldLabel: gettext('Provider'),
                },
                {
                    xtype: 'textfield',
                    name: 'region',
                    fieldLabel: gettext('Region'),
                },
                {
                    xtype: 'datefield',
                    name: 'expires',
                    format: 'Y-m-d',
                    fieldLabel: gettext('Expires'),
                    emptyText: gettext('Never'),
                },
                {
                    xtype: 'proxmoxintegerfield',
                    name: 'max-bindings',
                    minValue: 0,
                    value: 1,
                    fieldLabel: gettext('Max. bindings'),
                    autoEl: {
                        tag: 'div',
                        'data-qtip': gettext('1 = exclusive to one environment, 0 = unlimited'),
                    },
                },
            ],
            columnB: [
                {
                    xtype: 'textfield',
                    name: 'notes',
                    fieldLabel: gettext('Notes'),
                },
            ],
        };

        me.callParent();

        if (!me.isCreate) {
            me.load({
                success: function (response) {
                    let data = response.result.data;
                    let values = Ext.apply({}, data);
                    values.expires = data.expires ? new Date(data.expires * 1000) : null;
                    delete values.password;
                    me.setValues(values);
                },
            });
        }
    },
});

Ext.define('PVE.dc.EnvProxyImport', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveEnvProxyImport',

    title: gettext('Import Proxies'),
    isCreate: true,
    method: 'POST',
    url: '/api2/extjs/cluster/environments/proxy-import',
    width: 600,

    // show the per-line result after the window closed
    apiCallDone: function (success, response) {
        if (!success) {
            return;
        }
        let res = response.result.data;
        let msg = Ext.String.format(gettext('{0} proxies added.'), res.added.length);
        if (res.errors.length) {
            msg += '<br><br>' + res.errors.map(Ext.htmlEncode).join('<br>');
        }
        Ext.Msg.alert(gettext('Import'), msg);
    },

    items: {
        xtype: 'inputpanel',
        onGetValues: function (values) {
            for (const k of ['provider', 'region']) {
                if (!values[k]) {
                    delete values[k];
                }
            }
            return values;
        },
        column1: [
            {
                xtype: 'proxmoxKVComboBox',
                name: 'default-type',
                fieldLabel: gettext('Default type'),
                value: 'http',
                comboItems: [
                    ['http', 'HTTP'],
                    ['https', 'HTTPS'],
                    ['socks5', 'SOCKS5'],
                ],
            },
            {
                xtype: 'textfield',
                name: 'provider',
                fieldLabel: gettext('Provider'),
            },
        ],
        column2: [
            {
                xtype: 'textfield',
                name: 'region',
                fieldLabel: gettext('Region'),
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'max-bindings',
                minValue: 0,
                value: 1,
                fieldLabel: gettext('Max. bindings'),
            },
        ],
        columnB: [
            {
                xtype: 'textarea',
                name: 'data',
                allowBlank: false,
                height: 220,
                fieldStyle: 'font-family: monospace;',
                emptyText:
                    'socks5://user:pass@203.0.113.10:1080\nhttp://203.0.113.11:8080\n203.0.113.12:3128:user:pass',
            },
        ],
    },
});

Ext.define('PVE.dc.EnvProxies', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.pveDcEnvProxies',

    stateful: true,
    stateId: 'grid-dc-env-proxies',

    selModel: { mode: 'MULTI' },

    controller: {
        xclass: 'Ext.app.ViewController',

        reload: function () {
            this.getView().rstore.load();
        },

        selected: function () {
            return this.getView().getSelection();
        },

        add: function () {
            let me = this;
            Ext.create('PVE.dc.EnvProxyEdit', {
                autoShow: true,
                listeners: { destroy: () => me.reload() },
            });
        },

        importProxies: function () {
            let me = this;
            Ext.create('PVE.dc.EnvProxyImport', {
                autoShow: true,
                listeners: { destroy: () => me.reload() },
            });
        },

        edit: function () {
            let me = this;
            let sel = me.selected();
            if (sel.length !== 1) {
                return;
            }
            Ext.create('PVE.dc.EnvProxyEdit', {
                autoShow: true,
                proxyId: sel[0].data.id,
                listeners: { destroy: () => me.reload() },
            });
        },

        setState: function (state) {
            let me = this;
            let sel = me.selected();
            let pending = sel.length;
            sel.forEach((rec) =>
                Proxmox.Utils.API2Request({
                    url: `/cluster/environments/proxies/${rec.data.id}`,
                    method: 'PUT',
                    params: { state },
                    failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
                    callback: () => --pending === 0 && me.reload(),
                }),
            );
        },

        enable: function () {
            this.setState('active');
        },

        disable: function () {
            this.setState('disabled');
        },

        check: function () {
            let me = this;
            let sel = me.selected();
            let results = [];
            let next = function (i) {
                if (i >= sel.length) {
                    me.getView().setLoading(false);
                    me.reload();
                    Ext.Msg.alert(gettext('Check'), results.join('<br>'));
                    return;
                }
                let proxy = sel[i].data;
                Proxmox.Utils.API2Request({
                    url: `/cluster/environments/proxies/${proxy.id}/check`,
                    method: 'POST',
                    timeout: 60000,
                    failure: (response) => {
                        results.push(`${Ext.htmlEncode(proxy.label)}: ${response.htmlStatus}`);
                        next(i + 1);
                    },
                    success: (response) => {
                        let r = response.result.data;
                        let text = r.ok
                            ? `OK, ${r.ip}${r.country ? ' (' + r.country + ')' : ''}, ${r.latency} ms`
                            : `${gettext('Error')}: ${r.error}`;
                        let events = (r.events ?? []).map((e) => `&nbsp;&nbsp;${e}`);
                        results.push(
                            Ext.htmlEncode(`${proxy.label}: ${text}`),
                            ...events.map(Ext.htmlEncode),
                        );
                        next(i + 1);
                    },
                });
            };
            if (sel.length) {
                me.getView().setLoading(gettext('Checking...'));
                next(0);
            }
        },

        checkAll: function () {
            let me = this;
            Proxmox.Utils.API2Request({
                url: '/cluster/environments/proxy-check',
                method: 'POST',
                failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
                success: (response) =>
                    Ext.create('Proxmox.window.TaskViewer', {
                        autoShow: true,
                        upid: response.result.data,
                        listeners: { destroy: () => me.reload() },
                    }),
            });
        },

        remove: function () {
            let me = this;
            let sel = me.selected();
            if (sel.length !== 1) {
                return;
            }
            let proxy = sel[0].data;
            let bound = proxy.bindings ?? [];
            let msg = Ext.String.format(
                gettext('Remove proxy {0}?'),
                Ext.htmlEncode(proxy.label),
            );
            if (bound.length) {
                msg +=
                    '<br><br>' +
                    Ext.String.format(
                        gettext('It is bound to {0}. These bindings will be removed.'),
                        bound.join(', '),
                    );
            }
            Ext.Msg.confirm(gettext('Confirm'), msg, (btn) => {
                if (btn !== 'yes') {
                    return;
                }
                Proxmox.Utils.API2Request({
                    url: `/cluster/environments/proxies/${proxy.id}`,
                    method: 'DELETE',
                    params: bound.length ? { force: 1 } : {},
                    failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
                    callback: () => me.reload(),
                });
            });
        },

        onSelectionChange: function () {
            let me = this;
            let sel = me.selected();
            me.lookup('editBtn').setDisabled(sel.length !== 1);
            me.lookup('removeBtn').setDisabled(sel.length !== 1);
            me.lookup('checkBtn').setDisabled(!sel.length);
            me.lookup('enableBtn').setDisabled(!sel.some((r) => r.data.state !== 'active'));
            me.lookup('disableBtn').setDisabled(!sel.some((r) => r.data.state !== 'disabled'));
        },

        init: function () {
            this.onSelectionChange();
        },
    },

    listeners: {
        selectionchange: 'onSelectionChange',
        itemdblclick: 'edit',
    },

    tbar: [
        { text: gettext('Add'), iconCls: 'fa fa-plus-circle', handler: 'add' },
        { text: gettext('Import'), iconCls: 'fa fa-upload', handler: 'importProxies' },
        { text: gettext('Edit'), reference: 'editBtn', iconCls: 'fa fa-pencil', handler: 'edit' },
        '-',
        {
            text: gettext('Check'),
            reference: 'checkBtn',
            iconCls: 'fa fa-stethoscope',
            handler: 'check',
        },
        { text: gettext('Check all'), iconCls: 'fa fa-heartbeat', handler: 'checkAll' },
        '-',
        { text: gettext('Enable'), reference: 'enableBtn', iconCls: 'fa fa-check', handler: 'enable' },
        { text: gettext('Disable'), reference: 'disableBtn', iconCls: 'fa fa-ban', handler: 'disable' },
        {
            text: gettext('Remove'),
            reference: 'removeBtn',
            iconCls: 'fa fa-trash-o',
            handler: 'remove',
        },
    ],

    columns: [
        { header: gettext('Proxy'), dataIndex: 'label', flex: 2, renderer: Ext.htmlEncode },
        {
            header: gettext('State'),
            dataIndex: 'state',
            width: 110,
            renderer: (value, meta, rec) => PVE.Utils.render_env_proxy_state(value, rec.data),
        },
        { header: gettext('Exit IP'), dataIndex: 'exit-ip', width: 140 },
        { header: gettext('Country'), dataIndex: 'exit-country', width: 70 },
        {
            header: gettext('Latency'),
            dataIndex: 'latency',
            width: 80,
            renderer: (v) => (v !== undefined ? `${v} ms` : ''),
        },
        {
            header: gettext('Last check'),
            dataIndex: 'checked',
            width: 150,
            renderer: (v) => (v ? Proxmox.Utils.render_timestamp(v) : ''),
        },
        {
            header: gettext('Bound to'),
            dataIndex: 'bindings',
            flex: 1,
            renderer: (v, meta, rec) =>
                `${(v ?? []).join(', ')} (${rec.data.bindcount}/${(rec.data['max-bindings'] ?? 1) || '∞'})`,
        },
        { header: gettext('Provider'), dataIndex: 'provider', width: 100, renderer: Ext.htmlEncode },
        { header: gettext('Region'), dataIndex: 'region', width: 80, renderer: Ext.htmlEncode },
        {
            header: gettext('Expires'),
            dataIndex: 'expires',
            width: 100,
            renderer: (v) => (v ? Ext.Date.format(new Date(v * 1000), 'Y-m-d') : ''),
        },
        { header: 'ID', dataIndex: 'id', width: 100, hidden: true },
        {
            header: gettext('Notes'),
            dataIndex: 'notes',
            flex: 1,
            hidden: true,
            renderer: Ext.htmlEncode,
        },
    ],

    initComponent: function () {
        let me = this;

        me.rstore = Ext.create('Proxmox.data.UpdateStore', {
            storeid: 'pve-dc-env-proxies',
            interval: 10000,
            model: 'pve-env-proxy',
            proxy: {
                type: 'proxmox',
                url: '/api2/json/cluster/environments/proxies',
            },
        });
        me.store = Ext.create('Proxmox.data.DiffStore', {
            rstore: me.rstore,
            sorters: [{ property: 'label', direction: 'ASC' }],
        });

        me.callParent();

        Proxmox.Utils.monStoreErrors(me, me.rstore);
        me.on('activate', () => me.rstore.startUpdate());
        me.on('deactivate', () => me.rstore.stopUpdate());
        me.on('destroy', () => me.rstore.stopUpdate());
    },
});

Ext.define('PVE.window.EnvProxyBind', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveEnvProxyBind',

    subject: gettext('Proxy binding'),
    isCreate: true,
    isAdd: true,
    method: 'POST',
    width: 520,

    initComponent: function () {
        let me = this;
        if (!me.envId) {
            throw 'no environment ID specified';
        }
        me.url = `/api2/extjs/cluster/environments/envs/${me.envId}/proxy`;

        me.items = {
            xtype: 'inputpanel',
            column1: [
                {
                    xtype: 'proxmoxComboGrid',
                    name: 'proxy',
                    fieldLabel: gettext('Proxy'),
                    allowBlank: false,
                    valueField: 'id',
                    displayField: 'label',
                    store: {
                        model: 'pve-env-proxy',
                        autoLoad: true,
                        proxy: {
                            type: 'proxmox',
                            url: '/api2/json/cluster/environments/proxies',
                        },
                        filters: [
                            (rec) =>
                                rec.data.state === 'active' &&
                                !rec.data.expired &&
                                (!(rec.data['max-bindings'] ?? 1) ||
                                    rec.data.bindcount < (rec.data['max-bindings'] ?? 1)),
                        ],
                    },
                    listConfig: {
                        width: 500,
                        columns: [
                            { header: gettext('Proxy'), dataIndex: 'label', flex: 1 },
                            { header: gettext('Exit IP'), dataIndex: 'exit-ip', width: 120 },
                            { header: gettext('Country'), dataIndex: 'exit-country', width: 70 },
                            { header: gettext('Region'), dataIndex: 'region', width: 80 },
                        ],
                    },
                },
            ],
        };

        me.callParent();
    },
});
