Ext.define('pve-environment', {
    extend: 'Ext.data.Model',
    fields: [
        'id',
        'name',
        'vmid',
        'node',
        'template',
        'os',
        'owner',
        'description',
        'state',
        'status',
        'health',
        'error',
        'task',
        'lock',
        'created',
        { name: 'cpu', type: 'float' },
        { name: 'maxcpu', type: 'float' },
        { name: 'mem', type: 'int' },
        { name: 'maxmem', type: 'int' },
        { name: 'disk', type: 'int' },
        { name: 'maxdisk', type: 'int' },
        { name: 'uptime', type: 'int' },
    ],
    idProperty: 'id',
});

Ext.define('PVE.dc.Environments', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.pveDcEnvironments',

    onlineHelp: 'chapter_virtual_machines',

    stateful: true,
    stateId: 'grid-dc-environments',

    selModel: {
        mode: 'MULTI',
    },

    viewConfig: {
        trackOver: false,
    },

    controller: {
        xclass: 'Ext.app.ViewController',

        selected: function () {
            return this.getView().getSelection();
        },

        reload: function () {
            this.getView().rstore.load();
        },

        create: function () {
            let me = this;
            Ext.create('PVE.window.EnvironmentCreate', {
                autoShow: true,
                listeners: { destroy: () => me.reload() },
            });
        },

        adopt: function () {
            let me = this;
            Ext.create('PVE.window.EnvironmentAdopt', {
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
            Ext.create('PVE.window.EnvironmentEdit', {
                autoShow: true,
                envId: sel[0].data.id,
                listeners: { destroy: () => me.reload() },
            });
        },

        limits: function () {
            Ext.create('PVE.window.EnvironmentOptions', { autoShow: true });
        },

        runAction: function (action) {
            let me = this;
            let ids = me.selected()
                .filter((rec) => rec.data.vmid !== undefined && rec.data.state !== 'creating')
                .map((rec) => rec.data.id);
            if (!ids.length) {
                return;
            }

            let doRequest = () =>
                Proxmox.Utils.API2Request({
                    url: '/cluster/environments/action',
                    method: 'POST',
                    params: { action, ids },
                    waitMsgTarget: me.getView(),
                    failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
                    success: (response) => {
                        Ext.create('Proxmox.window.TaskProgress', {
                            autoShow: true,
                            upid: response.result.data,
                            taskDone: () => me.reload(),
                        });
                    },
                });

            if (action === 'start') {
                doRequest();
                return;
            }

            let actionText = {
                shutdown: gettext('Shutdown'),
                stop: gettext('Stop'),
                reboot: gettext('Reboot'),
            }[action];
            Ext.Msg.confirm(
                gettext('Confirm'),
                Ext.String.format(gettext('{0} {1} environment(s)?'), actionText, ids.length),
                (btn) => btn === 'yes' && doRequest(),
            );
        },

        start: function () {
            this.runAction('start');
        },
        shutdown: function () {
            this.runAction('shutdown');
        },
        stop: function () {
            this.runAction('stop');
        },
        reboot: function () {
            this.runAction('reboot');
        },

        console: function () {
            let sel = this.selected();
            if (sel.length !== 1) {
                return;
            }
            let env = sel[0].data;
            PVE.Utils.openDefaultConsoleWindow(true, 'kvm', env.vmid, env.node, env.name);
        },

        gotoVM: function () {
            let sel = this.selected();
            if (sel.length !== 1 || sel[0].data.vmid === undefined) {
                return;
            }
            let tree = Ext.ComponentQuery.query('pveResourceTree')[0];
            if (tree) {
                tree.selectById(`qemu/${sel[0].data.vmid}`);
            }
        },

        remove: function (keepVM) {
            let me = this;
            let sel = me.selected();
            if (sel.length !== 1) {
                return;
            }
            let env = sel[0].data;

            let msg = keepVM
                ? Ext.String.format(
                      gettext('Stop managing environment {0}? The VM {1} is kept.'),
                      Ext.htmlEncode(env.name),
                      env.vmid ?? '-',
                  )
                : Ext.String.format(
                      gettext(
                          'Delete environment {0}? Its VM {1} and all its disks will be destroyed.',
                      ),
                      Ext.htmlEncode(env.name),
                      env.vmid ?? '-',
                  );

            Ext.Msg.confirm(gettext('Confirm'), msg, (btn) => {
                if (btn !== 'yes') {
                    return;
                }
                Proxmox.Utils.API2Request({
                    url: `/cluster/environments/envs/${env.id}`,
                    method: 'DELETE',
                    params: keepVM ? { 'keep-vm': 1 } : {},
                    waitMsgTarget: me.getView(),
                    failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
                    success: (response) => {
                        let upid = response.result.data;
                        if (upid) {
                            Ext.create('Proxmox.window.TaskProgress', {
                                autoShow: true,
                                upid,
                                taskDone: () => me.reload(),
                            });
                        }
                        me.reload();
                    },
                });
            });
        },

        removeEnv: function () {
            this.remove(false);
        },

        unregister: function () {
            this.remove(true);
        },

        showTask: function () {
            let sel = this.selected();
            if (sel.length === 1 && sel[0].data.task) {
                Ext.create('Proxmox.window.TaskViewer', { autoShow: true, upid: sel[0].data.task });
            }
        },

        onSelectionChange: function () {
            let me = this;
            let sel = me.selected();
            let one = sel.length === 1 ? sel[0].data : undefined;
            let hasVM = sel.some((r) => r.data.vmid !== undefined && r.data.status !== 'absent');
            let anyRunning = sel.some((r) => r.data.status === 'running');
            let anyStopped = sel.some((r) => r.data.status === 'stopped');

            me.lookup('startBtn').setDisabled(!anyStopped);
            me.lookup('shutdownBtn').setDisabled(!anyRunning);
            me.lookup('stopBtn').setDisabled(!anyRunning);
            me.lookup('rebootBtn').setDisabled(!anyRunning);
            me.lookup('consoleBtn').setDisabled(!(one && one.status === 'running'));
            me.lookup('editBtn').setDisabled(!one);
            me.lookup('removeBtn').setDisabled(!one || one.state === 'creating');
            me.lookup('taskBtn').setDisabled(!(one && one.task));
            me.lookup('gotoBtn').setDisabled(!(one && hasVM));
        },

        init: function (view) {
            let me = this;
            view.rstore.on('load', () => me.onSelectionChange());
            me.onSelectionChange();
        },
    },

    listeners: {
        selectionchange: 'onSelectionChange',
        itemdblclick: 'gotoVM',
    },

    tbar: [
        {
            text: gettext('Create'),
            iconCls: 'fa fa-plus-circle',
            handler: 'create',
        },
        {
            text: gettext('Start'),
            reference: 'startBtn',
            iconCls: 'fa fa-play',
            handler: 'start',
        },
        {
            text: gettext('Shutdown'),
            reference: 'shutdownBtn',
            iconCls: 'fa fa-power-off',
            handler: 'shutdown',
        },
        {
            text: gettext('Stop'),
            reference: 'stopBtn',
            iconCls: 'fa fa-stop',
            handler: 'stop',
        },
        {
            text: gettext('Reboot'),
            reference: 'rebootBtn',
            iconCls: 'fa fa-refresh',
            handler: 'reboot',
        },
        '-',
        {
            text: gettext('Console'),
            reference: 'consoleBtn',
            iconCls: 'fa fa-terminal',
            handler: 'console',
        },
        {
            text: gettext('Go to VM'),
            reference: 'gotoBtn',
            iconCls: 'fa fa-desktop',
            handler: 'gotoVM',
        },
        {
            text: gettext('Edit'),
            reference: 'editBtn',
            iconCls: 'fa fa-pencil',
            handler: 'edit',
        },
        {
            text: gettext('Task'),
            reference: 'taskBtn',
            iconCls: 'fa fa-list-alt',
            handler: 'showTask',
        },
        {
            xtype: 'splitbutton',
            text: gettext('Remove'),
            reference: 'removeBtn',
            iconCls: 'fa fa-trash-o',
            handler: 'removeEnv',
            menu: [
                {
                    text: gettext('Unmanage (keep VM)'),
                    iconCls: 'fa fa-chain-broken',
                    handler: 'unregister',
                },
            ],
        },
        '->',
        {
            text: gettext('Add existing VM'),
            iconCls: 'fa fa-plus',
            handler: 'adopt',
        },
        {
            text: gettext('Limits'),
            iconCls: 'fa fa-sliders',
            handler: 'limits',
        },
    ],

    columns: [
        {
            header: gettext('Name'),
            dataIndex: 'name',
            flex: 2,
            renderer: Ext.htmlEncode,
        },
        {
            header: gettext('Health'),
            dataIndex: 'health',
            width: 120,
            renderer: (value, meta, rec) => PVE.Utils.render_env_health(value, rec.data.error),
        },
        {
            header: gettext('Status'),
            dataIndex: 'status',
            width: 90,
        },
        {
            header: 'VMID',
            dataIndex: 'vmid',
            width: 80,
        },
        {
            header: gettext('Node'),
            dataIndex: 'node',
            width: 100,
        },
        {
            header: gettext('OS'),
            dataIndex: 'os',
            width: 90,
            renderer: (v) => PVE.Utils.render_env_os(v),
        },
        {
            header: gettext('CPU usage'),
            dataIndex: 'cpu',
            width: 130,
            renderer: Proxmox.Utils.render_cpu,
        },
        {
            header: gettext('Memory usage'),
            dataIndex: 'mem',
            width: 150,
            renderer: (value, meta, rec) =>
                rec.data.uptime && rec.data.maxmem
                    ? Proxmox.Utils.render_size_usage(value, rec.data.maxmem, true)
                    : '',
        },
        {
            header: gettext('Uptime'),
            dataIndex: 'uptime',
            width: 110,
            renderer: (v) => (v ? Proxmox.Utils.render_uptime(v) : ''),
        },
        {
            header: gettext('Owner'),
            dataIndex: 'owner',
            width: 120,
            renderer: Ext.htmlEncode,
        },
        {
            header: gettext('Template'),
            dataIndex: 'template',
            width: 80,
            hidden: true,
        },
        {
            header: gettext('Created'),
            dataIndex: 'created',
            width: 150,
            hidden: true,
            renderer: Proxmox.Utils.render_timestamp,
        },
        {
            header: 'ID',
            dataIndex: 'id',
            width: 110,
            hidden: true,
        },
        {
            header: gettext('Notes'),
            dataIndex: 'description',
            flex: 1,
            hidden: true,
            renderer: Ext.htmlEncode,
        },
    ],

    initComponent: function () {
        let me = this;

        me.rstore = Ext.create('Proxmox.data.UpdateStore', {
            storeid: 'pve-dc-environments',
            interval: 5000,
            model: 'pve-environment',
            proxy: {
                type: 'proxmox',
                url: '/api2/json/cluster/environments/envs',
            },
        });

        me.store = Ext.create('Proxmox.data.DiffStore', {
            rstore: me.rstore,
            sorters: [{ property: 'name', direction: 'ASC' }],
        });

        me.callParent();

        Proxmox.Utils.monStoreErrors(me, me.rstore);

        me.on('activate', () => me.rstore.startUpdate());
        me.on('deactivate', () => me.rstore.stopUpdate());
        me.on('destroy', () => me.rstore.stopUpdate());
    },
});
