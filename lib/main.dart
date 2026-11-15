import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import 'data/app_database.dart';
import 'domain/work_time.dart';
import 'features/accounts_screen.dart';
import 'features/calendar_screen.dart';
import 'features/summary_screen.dart';
import 'features/settings_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MisHorasApp());
}

class MisHorasApp extends StatelessWidget {
  const MisHorasApp({super.key});

  @override
  Widget build(BuildContext context) {
    const blue = Color(0xff3978f6);
    return MaterialApp(
      title: 'Mis Horas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: blue,
          primary: blue,
          surface: const Color(0xfff5f7fb),
        ),
        scaffoldBackgroundColor: const Color(0xfff5f7fb),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xfff5f7fb),
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: const CardThemeData(
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
      ),
      home: const _AppShell(),
    );
  }
}

class _AppShell extends StatefulWidget {
  const _AppShell();

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  final _homeKey = GlobalKey<_HomeScreenState>();
  int _selectedTab = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(
          index: _selectedTab,
          children: [
            HomeScreen(key: _homeKey),
            SummaryScreen(),
            CalendarScreen(
              onSelectDate: (date) {
                _homeKey.currentState?._selectDate(date);
                setState(() => _selectedTab = 0);
              },
            ),
            AccountsScreen(),
            SettingsScreen(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedTab,
          onDestinationSelected: (index) =>
              setState(() => _selectedTab = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Inicio',
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart_rounded),
              label: 'Resumen',
            ),
            NavigationDestination(
              icon: Icon(Icons.calendar_month_outlined),
              selectedIcon: Icon(Icons.calendar_month_rounded),
              label: 'Calendario',
            ),
            NavigationDestination(
              icon: Icon(Icons.account_balance_wallet_outlined),
              selectedIcon: Icon(Icons.account_balance_wallet_rounded),
              label: 'Cuentas',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_rounded),
              label: 'Ajustes',
            ),
          ],
        ),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _database = AppDatabase.instance;
  DateTime _selectedDate = DateTime.now();
  List<WorkMovement> _movements = [];
  List<Map<String, Object?>> _accounts = [];
  List<int> _targets = [480, 480, 480, 480, 480, 0, 0];
  Map<String, DayKind> _dayKinds = {};
  Map<String, int> _dateOverrides = {};
  Map<String, String> _dayNotes = {};
  List<Map<String, Object?>> _attachments = [];
  int _weekStartDay = 1;
  bool _loading = true;
  String? _error;

  DateTime get _weekStart => startOfWeek(_selectedDate, _weekStartDay);
  DateTime get _weekEnd => _weekStart.add(const Duration(days: 6));
  String get _selectedKey => dateKey(_selectedDate);
  DayKind get _selectedKind => _dayKinds[_selectedKey] ?? DayKind.work;
  List<WorkMovement> get _selectedMovements =>
      _movements.where((movement) => movement.date == _selectedKey).toList();
  int get _selectedWorked => sumWorked(_selectedMovements);
  int get _selectedTarget => _selectedKind == DayKind.work
      ? (_dateOverrides[_selectedKey] ?? dailyTarget(_selectedDate, _targets))
      : 0;
  int get _weekWorked => sumWorked(_movements);
  int get _weekGoal {
    var goal = 0;
    for (var index = 0; index < 7; index++) {
      final date = _weekStart.add(Duration(days: index));
      if ((_dayKinds[dateKey(date)] ?? DayKind.work) == DayKind.work) {
        goal += _dateOverrides[dateKey(date)] ?? dailyTarget(date, _targets);
      }
    }
    return goal;
  }

  @override
  void initState() {
    super.initState();
    _database.revision.addListener(_onDatabaseChanged);
    _reload();
  }

  @override
  void dispose() {
    _database.revision.removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _onDatabaseChanged() {
    if (mounted) _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final weekStartDay = await _database.weekStart();
      final start = startOfWeek(_selectedDate, weekStartDay);
      final results = await Future.wait<Object>([
        _database.movementsBetween(start, start.add(const Duration(days: 6))),
        _database.dayKindsBetween(start, start.add(const Duration(days: 6))),
        _database.dailyTargets(),
        _database.accounts(),
        _database.dateOverrides(),
        _database.dayNotesBetween(start, start.add(const Duration(days: 6))),
        _database.attachmentsForDate(_selectedDate),
      ]);
      if (!mounted) return;
      setState(() {
        _movements = results[0] as List<WorkMovement>;
        _dayKinds = results[1] as Map<String, DayKind>;
        _targets = results[2] as List<int>;
        _accounts = results[3] as List<Map<String, Object?>>;
        _dateOverrides = results[4] as Map<String, int>;
        _dayNotes = results[5] as Map<String, String>;
        _attachments = results[6] as List<Map<String, Object?>>;
        _weekStartDay = weekStartDay;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudieron cargar los datos: $error';
      });
    }
  }

  void _changeWeek(int amount) {
    setState(() => _selectedDate = _selectedDate.add(Duration(days: amount * 7)));
    _reload();
  }

  void _selectDate(DateTime date) {
    setState(() => _selectedDate = date);
    _reload();
  }

  Future<void> _changeDayKind(DayKind kind) async {
    await _database.saveDayKind(_selectedDate, kind);
  }

  Future<void> _editNote() async {
    final controller = TextEditingController(text: _dayNotes[_selectedKey] ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nota del día'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 1000,
          minLines: 3,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Añade un detalle sobre esta jornada…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note != null) await _database.saveDayNote(_selectedDate, note);
  }

  Future<void> _addAttachments() async {
    try {
      final attachmentDate = _selectedDate;
      final source = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Hacer una foto'),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
              ListTile(
                leading: const Icon(Icons.attach_file_rounded),
                title: const Text('Elegir foto o PDF'),
                onTap: () => Navigator.pop(context, 'files'),
              ),
            ],
          ),
        ),
      );
      if (source == null || !mounted) return;
      if (source == 'camera') {
        final photo = await ImagePicker().pickImage(
          source: ImageSource.camera,
          imageQuality: 100,
        );
        if (photo == null) return;
        final extension = photo.name.split('.').last.toLowerCase();
        final mime = switch (extension) {
          'png' => 'image/png',
          'webp' => 'image/webp',
          _ => 'image/jpeg',
        };
        await _database.addAttachment(
          date: attachmentDate,
          name: photo.name,
          mime: mime,
          bytes: photo.openRead(),
        );
        _message('Foto guardada y optimizada.');
        return;
      }
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'pdf',
        ],
      );
      if (result.isEmpty) return;
      var added = 0;
      for (final file in result) {
        final extension = file.extension?.toLowerCase() ?? '';
        final mime = switch (extension) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'png' => 'image/png',
          'webp' => 'image/webp',
          'heic' => 'image/heic',
          'heif' => 'image/heif',
          'pdf' => 'application/pdf',
          _ => 'application/octet-stream',
        };
        await _database.addAttachment(
          date: attachmentDate,
          name: file.name,
          mime: mime,
          bytes: file.readAsByteStream(),
        );
        added++;
      }
      if (added > 0) {
        _message(
          added == 1
              ? 'Adjunto guardado y optimizado.'
              : '$added adjuntos guardados y optimizados.',
        );
      }
    } catch (error) {
      _message('No se pudieron añadir los archivos: $error');
    }
  }

  Future<void> _shareAttachment(Map<String, Object?> attachment) async {
    final path = attachment['local_path'] as String?;
    if (path == null) {
      _message('No se encuentra el archivo adjunto.');
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            path,
            name: attachment['name'] as String,
            mimeType: attachment['mime'] as String,
          ),
        ],
        fileNameOverrides: [attachment['name'] as String],
      ),
    );
  }

  Future<void> _openAttachment(Map<String, Object?> attachment) async {
    final path = attachment['local_path'] as String?;
    if (path == null || !await File(path).exists()) {
      _message('No se encuentra el archivo adjunto.');
      return;
    }
    await OpenFilex.open(path, type: attachment['mime'] as String);
  }

  Future<void> _deleteAttachment(Map<String, Object?> attachment) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar adjunto'),
        content: Text('¿Eliminar «${attachment['name']}»?'),
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
    if (confirm == true) {
      await _database.deleteAttachment(attachment['id'] as int);
    }
  }

  Future<void> _editMovement([WorkMovement? movement]) async {
    if (_selectedKind != DayKind.work) {
      _message('Cambia el estado del día a Trabajo para registrar horas.');
      return;
    }
    if (_accounts.isEmpty) {
      _message('No hay ninguna cuenta activa.');
      return;
    }
    final result = await showDialog<WorkMovement>(
      context: context,
      builder: (context) => MovementDialog(
        date: _selectedDate,
        accounts: _accounts,
        movement: movement,
      ),
    );
    if (result == null) return;
    final overlaps = _movements.any((current) {
      if (current.id == movement?.id || current.date != result.date) return false;
      final currentEnd =
          current.endMinute + (current.crossesMidnight ? 1440 : 0);
      final newEnd = result.endMinute + (result.crossesMidnight ? 1440 : 0);
      return result.startMinute < currentEnd && current.startMinute < newEnd;
    });
    if (overlaps) {
      _message('Este tramo coincide con otro horario registrado.');
      return;
    }
    await _database.saveMovement(result);
  }

  Future<void> _deleteMovement(WorkMovement movement) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar tramo'),
        content: const Text('¿Quieres eliminar este registro de horas?'),
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
    if (shouldDelete == true && movement.id != null) {
      await _database.deleteMovement(movement.id!);
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final weeklyGoal = _weekGoal;
    final weeklyExtra = (_weekWorked - weeklyGoal).clamp(0, 1 << 30);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xffe8efff),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(Icons.schedule_rounded, color: Color(0xff3978f6)),
            ),
            const SizedBox(width: 11),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mis Horas',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                Text(
                  'Tu jornada, bajo control',
                  style: TextStyle(fontSize: 11, color: Color(0xff7a8496)),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Ir a hoy',
            onPressed: () {
              setState(() => _selectedDate = DateTime.now());
              _reload();
            },
            icon: const Icon(Icons.today_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _reload)
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 112),
                    children: [
                      _weekHeader(),
                      const SizedBox(height: 17),
                      _weekCard(weeklyGoal, weeklyExtra),
                      const SizedBox(height: 23),
                      _weekDays(),
                      const SizedBox(height: 25),
                      _dayHeading(),
                      const SizedBox(height: 13),
                      _daySummary(),
                      const SizedBox(height: 13),
                      if (_selectedMovements.isEmpty)
                        _emptyMovements()
                      else
                        ..._selectedMovements.map(_movementCard),
                      const SizedBox(height: 16),
                      if (_selectedKind == DayKind.work)
                        FilledButton.icon(
                          onPressed: () => _editMovement(),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Añadir tramo'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(54),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(17),
                            ),
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      const SizedBox(height: 22),
                      _noteCard(),
                      const SizedBox(height: 18),
                      _attachmentsSection(),
                    ],
                  ),
                ),
    );
  }

  Widget _weekHeader() => Row(
        children: [
          IconButton.filledTonal(
            onPressed: () => _changeWeek(-1),
            icon: const Icon(Icons.chevron_left_rounded),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  _weekLabel(),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'RESUMEN SEMANAL',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xff8a94a6),
                  ),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            onPressed: () => _changeWeek(1),
            icon: const Icon(Icons.chevron_right_rounded),
            visualDensity: VisualDensity.compact,
          ),
        ],
      );

  Widget _weekCard(int goal, int extra) {
    final progress = goal == 0 ? 0.0 : (_weekWorked / goal).clamp(0.0, 1.0);
    final remaining = (goal - _weekWorked).clamp(0, 1 << 30);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xff18294a), Color(0xff263f70)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2218294a),
            blurRadius: 22,
            offset: Offset(0, 9),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Horas trabajadas',
                  style: TextStyle(color: Color(0xffd2daea), fontSize: 13),
                ),
              ),
              const Icon(Icons.insights_rounded,
                  color: Color(0xffa8c2ff), size: 20),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatMinutes(_weekWorked),
                style: const TextStyle(
                  fontSize: 31,
                  height: 1.1,
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'de ${formatMinutes(goal)}',
                  style: const TextStyle(color: Color(0xffc0cce0)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 17),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: const Color(0xff425577),
              valueColor:
                  const AlwaysStoppedAnimation<Color>(Color(0xff87aaff)),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _WeekMetric(
                label: extra > 0 ? 'Horas extra' : 'Restantes',
                value: formatMinutes(extra > 0 ? extra : remaining),
                icon: extra > 0
                    ? Icons.trending_up_rounded
                    : Icons.hourglass_bottom_rounded,
                accent: extra > 0
                    ? const Color(0xff9df0ce)
                    : const Color(0xffd2daea),
              ),
              const Spacer(),
              Text(
                '${(progress * 100).round()}%',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _weekDays() => Row(
        children: List.generate(7, (index) {
          final date = _weekStart.add(Duration(days: index));
          final key = dateKey(date);
          final isSelected = key == _selectedKey;
          final kind = _dayKinds[key] ?? DayKind.work;
          final worked = sumWorked(
            _movements.where((movement) => movement.date == key),
          );
          final target = kind == DayKind.work ? dailyTarget(date, _targets) : 0;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: index == 6 ? 0 : 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(17),
                onTap: () {
                  setState(() => _selectedDate = date);
                  _reload();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xff3978f6) : Colors.white,
                    borderRadius: BorderRadius.circular(17),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xff3978f6)
                          : const Color(0xffe8ebf1),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        _weekdayShort(date.weekday),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? const Color(0xffdce7ff)
                              : const Color(0xff8993a5),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        '${date.day}',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: isSelected ? Colors.white : const Color(0xff243047),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: worked > 0
                              ? (isSelected ? Colors.white : const Color(0xff3978f6))
                              : target > 0 && !isSelected
                                  ? const Color(0xffdbe2ef)
                                  : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      );

  Widget _dayHeading() => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _longDate(_selectedDate),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.35,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _selectedKind == DayKind.work
                      ? 'Jornada y tramos registrados'
                      : 'El objetivo de hoy está ajustado',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff8993a5),
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<DayKind>(
            tooltip: 'Cambiar estado del día',
            initialValue: _selectedKind,
            onSelected: _changeDayKind,
            itemBuilder: (context) => DayKind.values
                .map(
                  (kind) => PopupMenuItem(
                    value: kind,
                    child: Text('${kind.emoji}  ${kind.label}'),
                  ),
                )
                .toList(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xffe8ebf1)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_selectedKind.emoji),
                  const SizedBox(width: 6),
                  const Icon(Icons.expand_more_rounded, size: 18),
                ],
              ),
            ),
          ),
        ],
      );

  Widget _daySummary() {
    final remaining = (_selectedTarget - _selectedWorked).clamp(0, 1 << 30);
    final extra = (_selectedWorked - _selectedTarget).clamp(0, 1 << 30);
    return Row(
      children: [
        Expanded(
          child: _SmallStat(
            label: 'Trabajadas',
            value: formatMinutes(_selectedWorked),
            icon: Icons.timer_outlined,
            color: const Color(0xff3978f6),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SmallStat(
            label: 'Objetivo',
            value: formatMinutes(_selectedTarget),
            icon: Icons.flag_outlined,
            color: const Color(0xff8264d8),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SmallStat(
            label: extra > 0 ? 'Exceso' : 'Pendientes',
            value: formatMinutes(extra > 0 ? extra : remaining),
            icon: extra > 0
                ? Icons.north_east_rounded
                : Icons.hourglass_empty_rounded,
            color: extra > 0
                ? const Color(0xff119b70)
                : const Color(0xffd58b2e),
          ),
        ),
      ],
    );
  }

  Widget _emptyMovements() => Container(
        padding: const EdgeInsets.symmetric(vertical: 25, horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xffe8ebf1)),
        ),
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Color(0xffedf2ff),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.more_time_rounded,
                color: Color(0xff3978f6),
              ),
            ),
            const SizedBox(height: 11),
            const Text(
              'Aún no hay tramos',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const SizedBox(height: 4),
            const Text(
              'Añade tu horario para llevar el seguimiento del día.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xff8993a5), fontSize: 12),
            ),
          ],
        ),
      );

  Widget _noteCard() {
    final note = _dayNotes[_selectedKey] ?? '';
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ListTile(
        onTap: _editNote,
        leading: const Icon(Icons.notes_rounded, color: Color(0xff3978f6)),
        title: const Text('Nota del día',
            style: TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          note.isEmpty ? 'Añade un comentario o recordatorio' : note,
          maxLines: note.isEmpty ? 1 : 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.edit_outlined, size: 19),
      ),
    );
  }

  Widget _attachmentsSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Adjuntos',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              ),
              Text('${_attachments.length}',
                  style: const TextStyle(color: Color(0xff8993a5))),
            ],
          ),
          const SizedBox(height: 9),
          if (_attachments.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                'Guarda fotos o documentos asociados a este día.',
                style: TextStyle(color: Color(0xff8993a5), fontSize: 12),
              ),
            )
          else
            ..._attachments.map(_attachmentCard),
          OutlinedButton.icon(
            onPressed: _addAttachments,
            icon: const Icon(Icons.attach_file_rounded),
            label: const Text('Añadir foto o PDF'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
            ),
          ),
        ],
      );

  Widget _attachmentCard(Map<String, Object?> attachment) {
    final mime = attachment['mime'] as String;
    final isImage = mime.startsWith('image/');
    final thumbnailPath = attachment['local_thumbnail_path'] as String?;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        onTap: () => isImage
            ? _previewImage(attachment)
            : _openAttachment(attachment),
        leading: isImage
            ? thumbnailPath == null
                ? const CircleAvatar(
                    backgroundColor: Color(0xffedf2ff),
                    child: Icon(Icons.image_outlined, color: Color(0xff3978f6)),
                  )
                : ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: Image.file(
                  File(thumbnailPath),
                  width: 42,
                  height: 42,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const Icon(Icons.image_outlined),
                ),
              )
            : const CircleAvatar(
                backgroundColor: Color(0xffffeeee),
                child: Icon(Icons.picture_as_pdf_rounded,
                    color: Color(0xffd75252)),
              ),
        title: Text(attachment['name'] as String,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        subtitle: Text(
          '${((attachment['size'] as int) / 1024).toStringAsFixed(0)} KB',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (action) {
            if (action == 'share') _shareAttachment(attachment);
            if (action == 'delete') _deleteAttachment(attachment);
            if (action == 'open') _openAttachment(attachment);
          },
          itemBuilder: (context) => [
            if (isImage)
              const PopupMenuItem(value: 'share', child: Text('Compartir')),
            if (!isImage)
              const PopupMenuItem(value: 'open', child: Text('Abrir PDF')),
            if (!isImage)
              const PopupMenuItem(value: 'share', child: Text('Compartir')),
            const PopupMenuItem(value: 'delete', child: Text('Eliminar')),
          ],
        ),
      ),
    );
  }

  Future<void> _previewImage(Map<String, Object?> attachment) =>
      showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          insetPadding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 6, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(attachment['name'] as String,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    IconButton(
                      tooltip: 'Compartir',
                      onPressed: () => _shareAttachment(attachment),
                      icon: const Icon(Icons.share_outlined),
                    ),
                    IconButton(
                      tooltip: 'Cerrar',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: InteractiveViewer(
                  child: Image.file(
                    File(attachment['local_path'] as String),
                    fit: BoxFit.contain,
                    cacheWidth: 2560,
                    errorBuilder: (context, error, stackTrace) =>
                        const Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      );

  Widget _movementCard(WorkMovement movement) {
    final account = _accounts.firstWhere(
      (item) => item['id'] == movement.accountId,
      orElse: () => {'name': 'Trabajo', 'color': 0xff3978f6},
    );
    final color = Color(account['color'] as int);
    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _editMovement(movement),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(15, 14, 7, 14),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 43,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${formatClock(movement.startMinute)} – '
                      '${formatClock(movement.endMinute)}'
                      '${movement.crossesMidnight ? ' (+1 día)' : ''}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${account['name']} · pausa ${movement.breakMinutes} min',
                      style: const TextStyle(
                        color: Color(0xff8993a5),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                formatMinutes(movement.workedMinutes),
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (action) {
                  if (action == 'edit') _editMovement(movement);
                  if (action == 'delete') _deleteMovement(movement);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'edit', child: Text('Editar')),
                  PopupMenuItem(value: 'delete', child: Text('Eliminar')),
                ],
                icon: const Icon(Icons.more_vert_rounded, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _weekLabel() {
    const months = [
      'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'
    ];
    final start = _weekStart;
    final end = _weekEnd;
    if (start.month == end.month) {
      return '${start.day} – ${end.day} de ${months[end.month - 1]} ${end.year}';
    }
    return '${start.day} ${months[start.month - 1]} – '
        '${end.day} ${months[end.month - 1]} ${end.year}';
  }
}

class _WeekMetric extends StatelessWidget {
  const _WeekMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.accent,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, color: accent, size: 18),
          const SizedBox(width: 7),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: Color(0xffc0cce0), fontSize: 10)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w800,
                      fontSize: 13)),
            ],
          ),
        ],
      );
}

class _SmallStat extends StatelessWidget {
  const _SmallStat({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(11, 12, 9, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: const Color(0xffe8ebf1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(height: 9),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Color(0xff8993a5)),
            ),
          ],
        ),
      );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 38),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
}

class MovementDialog extends StatefulWidget {
  const MovementDialog({
    required this.date,
    required this.accounts,
    this.movement,
    super.key,
  });

  final DateTime date;
  final List<Map<String, Object?>> accounts;
  final WorkMovement? movement;

  @override
  State<MovementDialog> createState() => _MovementDialogState();
}

class _MovementDialogState extends State<MovementDialog> {
  late TimeOfDay _start;
  late TimeOfDay _end;
  late int _accountId;
  late final TextEditingController _breakController;
  String? _validationMessage;

  int _minuteOf(TimeOfDay time) => time.hour * 60 + time.minute;

  @override
  void initState() {
    super.initState();
    final movement = widget.movement;
    _start = movement == null
        ? const TimeOfDay(hour: 9, minute: 0)
        : TimeOfDay(
            hour: movement.startMinute ~/ 60,
            minute: movement.startMinute % 60,
          );
    _end = movement == null
        ? const TimeOfDay(hour: 17, minute: 0)
        : TimeOfDay(
            hour: movement.endMinute ~/ 60,
            minute: movement.endMinute % 60,
          );
    _accountId = movement?.accountId ?? widget.accounts.first['id'] as int;
    _breakController = TextEditingController(
      text: '${movement?.breakMinutes ?? 0}',
    );
  }

  @override
  void dispose() {
    _breakController.dispose();
    super.dispose();
  }

  Future<TimeOfDay?> _pickTime(TimeOfDay initial) => showTimePicker(
        context: context,
        initialTime: initial,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      );

  Future<void> _save() async {
    final start = _minuteOf(_start);
    final end = _minuteOf(_end);
    final crosses = end < start;
    final gross = end - start + (crosses ? 1440 : 0);
    final breakMinutes = int.tryParse(_breakController.text.trim());
    if (end == start) {
      setState(() => _validationMessage = 'El inicio y el fin no pueden coincidir.');
      return;
    }
    if (breakMinutes == null || breakMinutes < 0 || breakMinutes >= gross) {
      setState(() => _validationMessage = 'Revisa la duración de la pausa.');
      return;
    }
    Navigator.pop(
      context,
      WorkMovement(
        id: widget.movement?.id,
        date: dateKey(widget.date),
        accountId: _accountId,
        startMinute: start,
        endMinute: end,
        breakMinutes: breakMinutes,
        crossesMidnight: crosses,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.movement == null ? 'Añadir tramo' : 'Editar tramo'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<int>(
                initialValue: _accountId,
                decoration: const InputDecoration(labelText: 'Cuenta'),
                items: widget.accounts
                    .map(
                      (account) => DropdownMenuItem(
                        value: account['id'] as int,
                        child: Text(account['name'] as String),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => _accountId = value);
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final value = await _pickTime(_start);
                        if (value != null) setState(() => _start = value);
                      },
                      icon: const Icon(Icons.login_rounded, size: 18),
                      label: Text('Inicio ${_start.format(context)}'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final value = await _pickTime(_end);
                    if (value != null) setState(() => _end = value);
                  },
                  icon: const Icon(Icons.logout_rounded, size: 18),
                  label: Text('Fin ${_end.format(context)}'),
                ),
              ),
              const SizedBox(height: 9),
              TextField(
                controller: _breakController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Pausa',
                  suffixText: 'minutos',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_validationMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  _validationMessage!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(onPressed: _save, child: const Text('Guardar')),
        ],
      );
}

String _weekdayShort(int weekday) =>
    const ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'][weekday - 1];

String _longDate(DateTime date) {
  const weekdays = [
    'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'
  ];
  const months = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'
  ];
  final weekday = weekdays[date.weekday - 1];
  return '${weekday[0].toUpperCase()}${weekday.substring(1)}, '
      '${date.day} de ${months[date.month - 1]}';
}
