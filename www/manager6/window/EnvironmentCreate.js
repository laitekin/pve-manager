Ext.define('pve-env-template', {
    extend: 'Ext.data.Model',
    fields: ['vmid', 'node', 'name', 'ostype', 'os', 'maxcpu', 'maxmem', 'maxdisk'],
    idProperty: 'vmid',
});

Ext.define('PVE.form.EnvTemplateSelector', {
    extend: 'Proxmox.form.ComboGrid',
    alias: 'widget.pveEnvTemplateSelector',

    allowBlank: false,
    autoSelect: false,
    valueField: 'vmid',
    displayField: 'name',

    store: {
        model: 'pve-env-template',
        autoLoad: true,
        proxy: {
            type: 'proxmox',
            url: '/api2/json/cluster/environments/templates',
        },
        sorters: 'name',
    },

    listConfig: {
        width: 520,
        columns: [
            { header: 'ID', dataIndex: 'vmid', width: 70 },
            { header: gettext('Name'), dataIndex: 'name', flex: 1 },
            {
                header: gettext('OS'),
                dataIndex: 'os',
                width: 80,
                renderer: (v) => PVE.Utils.render_env_os(v),
            },
            { header: gettext('Node'), dataIndex: 'node', width: 90 },
            {
                header: gettext('Memory'),
                dataIndex: 'maxmem',
                width: 80,
                renderer: Proxmox.Utils.render_size,
            },
        ],
    },
});

Ext.define('PVE.window.EnvironmentCreate', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveEnvironmentCreate',

    subject: gettext('Environment'),
    isCreate: true,
    method: 'POST',
    url: '/cluster/environments/envs',
    showTaskViewer: true,
    width: 640,

    viewModel: {
        data: {
            templateNode: undefined,
            fullClone: true,
        },
    },

    controller: {
        xclass: 'Ext.app.ViewController',

        onTemplateChange: function (field, value) {
            let me = this;
            let rec = field.getStore().getById(value);
            let vm = me.getViewModel();
            if (!rec) {
                vm.set('templateNode', undefined);
                return;
            }
            vm.set('templateNode', rec.data.node);

            let storage = me.lookup('storage');
            storage.setNodename(me.lookup('target').getValue() || rec.data.node);

            let name = me.lookup('name');
            if (!name.getValue() && rec.data.name) {
                name.setValue(rec.data.name.replace(/[^a-zA-Z0-9.-]/g, '-'));
            }
        },

        onTargetChange: function (field, value) {
            let me = this;
            let node = value || me.getViewModel().get('templateNode');
            if (node) {
                me.lookup('storage').setNodename(node);
            }
        },
    },

    // one key per window, so that resubmitting after a timeout does not
    // create the environments a second time
    initComponent: function () {
        let me = this;
        me.requestId = `ui-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
        me.callParent();
    },

    getValues: function () {
        let me = this;
        let values = me.callParent(arguments);
        values['request-id'] = me.requestId;
        return values;
    },

    items: {
        xtype: 'inputpanel',
        onGetValues: function (values) {
            values.full = values.full ? 1 : 0;
            values.start = values.start ? 1 : 0;
            for (const key of ['target', 'storage', 'cores', 'memory', 'description']) {
                if (values[key] === '' || values[key] === undefined || values[key] === null) {
                    delete values[key];
                }
            }
            if (values.count === 1 || values.count === '1') {
                delete values.count;
            }
            return values;
        },
        column1: [
            {
                xtype: 'pveEnvTemplateSelector',
                name: 'template',
                fieldLabel: gettext('Template'),
                listeners: { change: 'onTemplateChange' },
            },
            {
                xtype: 'textfield',
                name: 'name',
                reference: 'name',
                vtype: 'DnsName',
                allowBlank: false,
                fieldLabel: gettext('Name'),
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'count',
                value: 1,
                minValue: 1,
                maxValue: 100,
                allowBlank: false,
                fieldLabel: gettext('Count'),
                autoEl: {
                    tag: 'div',
                    'data-qtip': gettext("With a count above 1, '-N' is appended to the name."),
                },
            },
            {
                xtype: 'proxmoxcheckbox',
                name: 'start',
                checked: true,
                uncheckedValue: 0,
                fieldLabel: gettext('Start after created'),
            },
        ],
        column2: [
            {
                xtype: 'proxmoxintegerfield',
                name: 'cores',
                minValue: 1,
                maxValue: 8192,
                allowBlank: true,
                emptyText: gettext('From template'),
                fieldLabel: gettext('Cores'),
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'memory',
                minValue: 16,
                step: 512,
                allowBlank: true,
                emptyText: gettext('From template'),
                fieldLabel: gettext('Memory') + ' (MiB)',
            },
            {
                xtype: 'pveNodeSelector',
                name: 'target',
                reference: 'target',
                allowBlank: true,
                onlineValidator: true,
                emptyText: gettext('Same as template'),
                fieldLabel: gettext('Target node'),
                listeners: { change: 'onTargetChange' },
            },
            {
                xtype: 'proxmoxcheckbox',
                name: 'full',
                checked: true,
                uncheckedValue: 0,
                fieldLabel: gettext('Full Clone'),
                bind: { value: '{fullClone}' },
            },
            {
                xtype: 'pveStorageSelector',
                name: 'storage',
                reference: 'storage',
                storageContent: 'images',
                allowBlank: true,
                autoSelect: false,
                emptyText: gettext('Same as source'),
                fieldLabel: gettext('Target Storage'),
                bind: {
                    disabled: '{!fullClone}',
                },
            },
        ],
        columnB: [
            {
                xtype: 'textarea',
                name: 'description',
                fieldLabel: gettext('Notes'),
                height: 60,
            },
        ],
    },
});

Ext.define('PVE.window.EnvironmentEdit', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveEnvironmentEdit',

    subject: gettext('Environment'),
    width: 480,

    initComponent: function () {
        let me = this;
        if (!me.envId) {
            throw 'no environment ID specified';
        }
        me.url = `/api2/extjs/cluster/environments/envs/${me.envId}`;
        me.callParent();
        me.load();
    },

    items: {
        xtype: 'inputpanel',
        onGetValues: function (values) {
            if (!values.owner) {
                delete values.owner;
            }
            return values;
        },
        column1: [
            {
                xtype: 'displayfield',
                name: 'id',
                fieldLabel: 'ID',
                submitValue: false,
            },
            {
                xtype: 'textfield',
                name: 'name',
                allowBlank: false,
                fieldLabel: gettext('Name'),
            },
            {
                xtype: 'pmxUserSelector',
                name: 'owner',
                allowBlank: true,
                fieldLabel: gettext('Owner'),
            },
            {
                xtype: 'textarea',
                name: 'description',
                fieldLabel: gettext('Notes'),
                height: 80,
            },
        ],
    },
});

Ext.define('PVE.window.EnvironmentOptions', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveEnvironmentOptions',

    subject: gettext('Environment Limits'),
    url: '/api2/extjs/cluster/environments/options',
    width: 420,

    initComponent: function () {
        let me = this;
        me.callParent();
        me.load();
    },

    items: {
        xtype: 'inputpanel',
        column1: [
            {
                xtype: 'proxmoxintegerfield',
                name: 'max-envs',
                minValue: 0,
                allowBlank: false,
                fieldLabel: gettext('Max. environments'),
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'max-running',
                minValue: 0,
                allowBlank: false,
                fieldLabel: gettext('Max. running'),
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'max-creating',
                minValue: 0,
                allowBlank: false,
                fieldLabel: gettext('Max. creating'),
            },
            {
                xtype: 'displayfield',
                value: gettext('0 means unlimited.'),
                userCls: 'pmx-hint',
            },
        ],
    },
});

Ext.define('PVE.window.EnvironmentAdopt', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveEnvironmentAdopt',

    subject: gettext('Existing VM'),
    isCreate: true,
    isAdd: true,
    method: 'POST',
    url: '/api2/extjs/cluster/environments/adopt',
    width: 420,

    items: {
        xtype: 'inputpanel',
        onGetValues: function (values) {
            if (!values.name) {
                delete values.name;
            }
            return values;
        },
        column1: [
            {
                xtype: 'pveGuestIDSelector',
                name: 'vmid',
                guestType: 'qemu',
                validateExists: true,
                loadNextFreeID: false,
            },
            {
                xtype: 'textfield',
                name: 'name',
                allowBlank: true,
                emptyText: gettext('VM name'),
                fieldLabel: gettext('Name'),
            },
        ],
    },
});
