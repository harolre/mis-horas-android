import 'package:material_ui/material_ui.dart';

import '../data/app_database.dart';
import '../domain/work_time.dart';

const _accountColors = [
  0xff3978f6,
  0xff0d9488,
  0xff7c3aed,
  0xffdb2777,
  0xffea580c,
  0xffca8a04,
  0xff0891b2,
  0xff4b5563,
];

class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  final _database = AppDatabase.instance;
  bool _loading = true;
  String? _error;
  List<Map<String, Object?>> _accounts = [];
  List<WorkMovement> _movements = [];

  @override
  void initState() {
    super.initState();
    _database.revision.addListener(_onDatabaseChanged);
    _load();
  }

  @override
  void dispose() {
    _database.revision.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _onDatabaseChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object>([
        _database.allAccounts(),
        _database.allMovements(),
      ]);
      if (!mounted) return;
      setState(() {
        _accounts = results[0] as List<Map<String, Object?>>;
        _movements = results[1] as List<WorkMovement>;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _editAccount([Map<String, Object?>? account]) async {
    final result = await showDialog<_AccountDraft>(
      context: context,
      builder: (context) => _AccountDialog(account: account),
    );
    if (result == null) return;
    try {
      if (account == null) {
        await _database.createAccount(result.name, result.color);
      } else {
        await _database.updateAccount(
          account['id'] as int,
          name: result.name,
          color: result.color,
        );
      }
      await _load();
    } catch (error) {
      _showMessage(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _toggleArchive(Map<String, Object?> account) async {
    final archived = account['archived'] == 1;
    try {
      await _database.updateAccount(
        account['id'] as int,
        archived: archived ? 0 : 1,
      );
      await _load();
      _showMessage(archived ? 'Cuenta reactivada.' : 'Cuenta archivada.');
    } catch (error) {
      _showMessage(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _delete(Map<String, Object?> account) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar cuenta'),
        content: Text('¿Eliminar «${account['name']}»? Esta acción no se puede deshacer.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _database.deleteAccount(account['id'] as int);
      await _load();
    } catch (error) {
      _showMessage(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  int _minutesFor(int id) => sumWorked(
        _movements.where((movement) => movement.accountId == id),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Cuentas',
              style: TextStyle(fontWeight: FontWeight.w800)),
          actions: [
            IconButton(
              tooltip: 'Añadir cuenta',
              onPressed: () => _editAccount(),
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _editAccount(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Nueva cuenta'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                      children: [
                        const Text(
                          'Organiza tus jornadas por cliente, proyecto o tipo de trabajo.',
                          style: TextStyle(
                              color: Color(0xff798397), height: 1.4),
                        ),
                        const SizedBox(height: 20),
                        ..._accounts.map(_accountTile),
                        if (_accounts.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: 50),
                            child: Center(child: Text('Todavía no hay cuentas.')),
                          ),
                      ],
                    ),
                  ),
      );

  Widget _accountTile(Map<String, Object?> account) {
    final id = account['id'] as int;
    final name = account['name'] as String;
    final color = Color(account['color'] as int);
    final archived = account['archived'] == 1;
    final minutes = _minutesFor(id);
    return Card(
      margin: const EdgeInsets.only(bottom: 11),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 14, 6, 14),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                name.substring(0, 1).toUpperCase(),
                style: TextStyle(
                    color: color, fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 15)),
                      ),
                      if (archived) ...[
                        const SizedBox(width: 7),
                        const Text('Archivada',
                            style: TextStyle(
                                color: Color(0xff8993a5), fontSize: 10)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${formatMinutes(minutes)} registradas',
                    style: const TextStyle(
                        color: Color(0xff8993a5), fontSize: 12),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (action) {
                if (action == 'edit') _editAccount(account);
                if (action == 'archive') _toggleArchive(account);
                if (action == 'delete') _delete(account);
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'edit', child: Text('Editar')),
                PopupMenuItem(
                  value: 'archive',
                  child: Text(archived ? 'Reactivar' : 'Archivar'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('Eliminar')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountDraft {
  const _AccountDraft(this.name, this.color);
  final String name;
  final int color;
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog({this.account});
  final Map<String, Object?>? account;

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  late final TextEditingController _name;
  late int _color;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.account?['name'] as String? ?? '');
    _color = widget.account?['color'] as int? ?? _accountColors.first;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.account == null ? 'Nueva cuenta' : 'Editar cuenta'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                maxLength: 40,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Nombre',
                  hintText: 'Ej. Cliente A',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              const Text('Color',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 11,
                runSpacing: 10,
                children: _accountColors.map((value) {
                  final selected = _color == value;
                  return InkWell(
                    onTap: () => setState(() => _color = value),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Color(value),
                        shape: BoxShape.circle,
                        border: selected
                            ? Border.all(color: Colors.black87, width: 3)
                            : null,
                      ),
                      child: selected
                          ? const Icon(Icons.check, color: Colors.white, size: 19)
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final name = _name.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(context, _AccountDraft(name, _color));
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      );
}
