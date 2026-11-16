import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/app_database.dart';
import '../data/mobile_backup_service.dart';
import '../domain/work_time.dart';

const _weekdays = [
  'Lunes',
  'Martes',
  'Miércoles',
  'Jueves',
  'Viernes',
  'Sábado',
  'Domingo',
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _database = AppDatabase.instance;
  final _controllers = List.generate(7, (_) => TextEditingController());
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _weekStart = 1;
  List<Map<String, Object?>> _accounts = [];
  int? _targetAccountId;
  int? _activeAccountId;

  @override
  void initState() {
    super.initState();
    _database.revision.addListener(_onDatabaseChanged);
    _load();
  }

  @override
  void dispose() {
    _database.revision.removeListener(_onDatabaseChanged);
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final accounts = await _database.accounts();
      final activeAccountId = await _database.activeAccountId();
      final selectedAccountId =
          accounts.any((account) => account['id'] == _targetAccountId)
          ? _targetAccountId!
          : activeAccountId;
      final results = await Future.wait<Object>([
        _database.dailyTargets(accountId: selectedAccountId),
        _database.weekStart(),
      ]);
      if (!mounted) return;
      _setControllerTargets(results[0] as List<int>);
      setState(() {
        _accounts = accounts;
        _targetAccountId = selectedAccountId;
        _activeAccountId = activeAccountId;
        _weekStart = results[1] as int;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _setControllerTargets(List<int> targets) {
    for (var index = 0; index < 7; index++) {
      _controllers[index].text = targets[index] == 0
          ? '0'
          : (targets[index] / 60)
                .toStringAsFixed(targets[index] % 60 == 0 ? 0 : 2)
                .replaceFirst(RegExp(r'\.?0+$'), '');
    }
  }

  void _onDatabaseChanged() {
    if (mounted && !_saving) _refreshAccounts();
  }

  Future<void> _refreshAccounts() async {
    try {
      final accounts = await _database.accounts();
      final activeAccountId = await _database.activeAccountId();
      if (!mounted) return;
      final accountChanged = activeAccountId != _activeAccountId;
      final selectedAccountId =
          accountChanged ||
              !accounts.any((account) => account['id'] == _targetAccountId)
          ? activeAccountId
          : _targetAccountId!;
      setState(() {
        _accounts = accounts;
        _activeAccountId = activeAccountId;
      });
      if (selectedAccountId != _targetAccountId) {
        await _selectTargetAccount(selectedAccountId);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _selectTargetAccount(int? accountId) async {
    if (accountId == null || accountId == _targetAccountId) return;
    setState(() {
      _targetAccountId = accountId;
      _saving = true;
      _error = null;
    });
    try {
      final targets = await _database.dailyTargets(accountId: accountId);
      if (mounted) _setControllerTargets(targets);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    final targets = <int>[];
    for (var index = 0; index < 7; index++) {
      final hours = double.tryParse(
        _controllers[index].text.trim().replaceAll(',', '.'),
      );
      if (hours == null || hours < 0 || hours > 24) {
        setState(
          () => _error =
              '${_weekdays[index]}: indica un valor entre 0 y 24 horas.',
        );
        return;
      }
      targets.add((hours * 60).round());
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final accountId = _targetAccountId;
      if (accountId == null) {
        throw StateError('Selecciona una cuenta para guardar sus objetivos.');
      }
      await _database.saveDailyTargets(targets, accountId: accountId);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Objetivos guardados.')));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveWeekStart(int? value) async {
    if (value == null) return;
    try {
      await _database.saveWeekStart(value);
      if (mounted) setState(() => _weekStart = value);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<List<String>?> _askBackupPassword({required bool confirm}) =>
      showDialog<List<String>>(
        context: context,
        builder: (context) => _BackupPasswordDialog(confirm: confirm),
      );

  Future<void> _exportBackup() async {
    final credentials = await _askBackupPassword(confirm: true);
    if (credentials == null) return;
    if (credentials[0].length < 8) {
      setState(
        () => _error = 'La contraseña debe tener al menos 8 caracteres.',
      );
      return;
    }
    if (credentials[0] != credentials[1]) {
      setState(() => _error = 'Las contraseñas no coinciden.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    File? backup;
    try {
      final now = DateTime.now();
      final filename = 'mis-horas-${dateKey(now)}.mhbackup';
      backup = await MobileBackupService.instance.createBackupFile(
        credentials[0],
      );
      if (!Platform.isAndroid) {
        throw UnsupportedError(
          'La exportación al selector de archivos de esta plataforma aún no está disponible.',
        );
      }
      final destination = await const MethodChannel(
        'com.harolre.mishoras/backup',
      ).invokeMethod<String>('createBackupDestination', {'fileName': filename});
      if (destination == null) return;
      final destinationUri = Uri.parse(destination);
      if (destinationUri.scheme == 'file') {
        final output = File(destinationUri.toFilePath()).openWrite();
        await output.addStream(backup.openRead());
        await output.close();
      } else {
        await const MethodChannel('com.harolre.mishoras/backup')
            .invokeMethod<void>('copyFileToUri', {
              'sourcePath': backup.path,
              'destinationUri': destination,
            });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copia cifrada guardada correctamente.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (backup != null && await backup.exists()) await backup.delete();
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _importBackup() async {
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['mhbackup'],
    );
    if (selected == null) return;
    if (!mounted) return;
    final credentials = await _askBackupPassword(confirm: false);
    if (credentials == null) return;
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reemplazar datos'),
        content: const Text(
          'Importar esta copia sustituirá todos los datos de Mis Horas en este dispositivo. '
          'Si quieres conservarlos, exporta una copia antes de continuar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reemplazar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    File? staged;
    try {
      final directory = await getTemporaryDirectory();
      staged = File(
        p.join(
          directory.path,
          'selected-${DateTime.now().microsecondsSinceEpoch}.mhbackup',
        ),
      );
      final sink = staged.openWrite();
      try {
        await sink.addStream(selected.readAsByteStream());
        await sink.close();
      } catch (_) {
        await sink.close();
        rethrow;
      }
      await MobileBackupService.instance.restoreFromFile(
        staged,
        credentials[0],
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copia restaurada correctamente.')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (staged != null && await staged.exists()) await staged.delete();
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'Ajustes',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              const Text(
                'Objetivos por cuenta',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 5),
              const Text(
                'Cada cuenta puede tener un horario distinto. Los días de vacaciones, festivo o baja no suman objetivo.',
                style: TextStyle(
                  color: Color(0xff798397),
                  height: 1.45,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 18),
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 5,
                  ),
                  child: DropdownButtonFormField<int>(
                    initialValue: _targetAccountId,
                    decoration: const InputDecoration(
                      labelText: 'Cuenta cuyos objetivos editas',
                      border: InputBorder.none,
                    ),
                    items: _accounts
                        .map(
                          (account) => DropdownMenuItem(
                            value: account['id'] as int,
                            child: Text(
                              account['id'] == _activeAccountId
                                  ? '${account['name']} · Activa'
                                  : account['name'] as String,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _saving ? null : _selectTargetAccount,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 5,
                  ),
                  child: DropdownButtonFormField<int>(
                    initialValue: _weekStart,
                    decoration: const InputDecoration(
                      labelText: 'La semana empieza el',
                      border: InputBorder.none,
                    ),
                    items: List.generate(
                      7,
                      (index) => DropdownMenuItem(
                        value: index + 1,
                        child: Text(_weekdays[index]),
                      ),
                    ),
                    onChanged: _saveWeekStart,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Horas previstas por día',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(21),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: List.generate(7, (index) {
                      final weekend = index >= 5;
                      return Padding(
                        padding: EdgeInsets.only(bottom: index == 6 ? 0 : 11),
                        child: Row(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Icon(
                                    weekend
                                        ? Icons.weekend_outlined
                                        : Icons.work_outline_rounded,
                                    size: 18,
                                    color: const Color(0xff758197),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    _weekdays[index],
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 112,
                              child: TextField(
                                controller: _controllers[index],
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                textAlign: TextAlign.end,
                                decoration: const InputDecoration(
                                  suffixText: 'h',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Guardar objetivos'),
              ),
              const SizedBox(height: 25),
              const Text(
                'Privacidad',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const ListTile(
                  leading: Icon(
                    Icons.phonelink_lock_outlined,
                    color: Color(0xff3978f6),
                  ),
                  title: Text('Datos guardados en este dispositivo'),
                  subtitle: Text(
                    'Mis Horas no crea una cuenta ni envía tus jornadas a un servidor.',
                  ),
                  isThreeLine: true,
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'Copias de seguridad',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 5),
              const Text(
                'Cifradas con contraseña. Guárdalas en Archivos o en otra ubicación segura y restáuralas desde aquí.',
                style: TextStyle(
                  color: Color(0xff798397),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 10),
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _exportBackup,
                          icon: const Icon(Icons.lock_outline_rounded),
                          label: const Text('Exportar copia cifrada'),
                        ),
                      ),
                      const SizedBox(height: 7),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _saving ? null : _importBackup,
                          icon: const Icon(Icons.restore_rounded),
                          label: const Text('Importar copia .mhbackup'),
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        'No olvides la contraseña: no se guarda y no se puede recuperar.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xff8993a5),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_saving) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
                const SizedBox(height: 5),
                const Text(
                  'Procesando copia segura…',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xff8993a5), fontSize: 11),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
  );
}

class _BackupPasswordDialog extends StatefulWidget {
  const _BackupPasswordDialog({required this.confirm});
  final bool confirm;

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.confirm ? 'Crear copia cifrada' : 'Desbloquear copia'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _password,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Contraseña',
            border: OutlineInputBorder(),
          ),
        ),
        if (widget.confirm) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _confirmation,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Repetir contraseña',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, [
          _password.text,
          widget.confirm ? _confirmation.text : '',
        ]),
        child: Text(widget.confirm ? 'Continuar' : 'Importar'),
      ),
    ],
  );
}
