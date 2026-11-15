import 'package:material_ui/material_ui.dart';

import '../data/app_database.dart';
import '../domain/work_time.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({required this.onSelectDate, super.key});

  final ValueChanged<DateTime> onSelectDate;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final _database = AppDatabase.instance;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  bool _loading = true;
  List<WorkMovement> _movements = [];
  Map<String, DayKind> _kinds = {};
  Map<String, int> _overrides = {};
  Map<String, int> _attachmentCounts = {};
  Map<String, String> _notes = {};
  List<int> _targets = [480, 480, 480, 480, 480, 0, 0];
  int _weekStartDay = 1;

  DateTime get _gridStart => startOfWeek(_month, _weekStartDay);
  DateTime get _gridEnd => _gridStart.add(const Duration(days: 41));

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
    setState(() => _loading = true);
    try {
      _weekStartDay = await _database.weekStart();
      final results = await Future.wait<Object>([
        _database.movementsBetween(_gridStart, _gridEnd),
        _database.dayKindsBetween(_gridStart, _gridEnd),
        _database.dateOverrides(),
        _database.dailyTargets(),
        _database.attachmentCountsBetween(_gridStart, _gridEnd),
        _database.dayNotesBetween(_gridStart, _gridEnd),
      ]);
      if (!mounted) return;
      setState(() {
        _movements = results[0] as List<WorkMovement>;
        _kinds = results[1] as Map<String, DayKind>;
        _overrides = results[2] as Map<String, int>;
        _targets = results[3] as List<int>;
        _attachmentCounts = results[4] as Map<String, int>;
        _notes = results[5] as Map<String, String>;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  int _worked(DateTime date) => sumWorked(
        _movements.where((movement) => movement.date == dateKey(date)),
      );

  int _target(DateTime date) {
    if ((_kinds[dateKey(date)] ?? DayKind.work) != DayKind.work) return 0;
    return _overrides[dateKey(date)] ?? dailyTarget(date, _targets);
  }

  void _moveMonth(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta));
    _load();
  }

  Future<void> _openDay(DateTime date) async {
    final worked = _worked(date);
    final kind = _kinds[dateKey(date)] ?? DayKind.work;
    final target = _target(date);
    final note = _notes[dateKey(date)] ?? '';
    final attachmentCount = _attachmentCounts[dateKey(date)] ?? 0;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _dateTitle(date),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text('${kind.emoji}  ${kind.label}',
                  style: const TextStyle(color: Color(0xff788397))),
              if (note.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(note, maxLines: 3, overflow: TextOverflow.ellipsis),
              ],
              if (attachmentCount > 0) ...[
                const SizedBox(height: 7),
                Text(
                  '$attachmentCount ${attachmentCount == 1 ? 'adjunto' : 'adjuntos'}',
                  style: const TextStyle(color: Color(0xff788397)),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _dayInfo('Trabajadas', formatMinutes(worked))),
                  Expanded(child: _dayInfo('Objetivo', formatMinutes(target))),
                ],
              ),
              const SizedBox(height: 17),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onSelectDate(date);
                  },
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: const Text('Abrir día en Inicio'),
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  final controller = TextEditingController(
                    text: (_overrides[dateKey(date)] ?? dailyTarget(date, _targets)) == 0
                        ? ''
                        : ((_overrides[dateKey(date)] ??
                                    dailyTarget(date, _targets)) /
                                60)
                            .toString(),
                  );
                  final value = await showDialog<int?>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Objetivo para este día'),
                      content: TextField(
                        controller: controller,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          labelText: 'Horas',
                          hintText: 'Vacío para usar el objetivo habitual',
                          suffixText: 'h',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancelar'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, -1),
                          child: const Text('Restablecer'),
                        ),
                        FilledButton(
                          onPressed: () {
                            final hours = double.tryParse(
                              controller.text.trim().replaceAll(',', '.'),
                            );
                            if (hours != null && hours >= 0 && hours <= 24) {
                              Navigator.pop(context, (hours * 60).round());
                            }
                          },
                          child: const Text('Guardar'),
                        ),
                      ],
                    ),
                  );
                  controller.dispose();
                  if (value != null) {
                    await _database.saveDateOverride(
                      date,
                      value < 0 ? null : value,
                    );
                    if (context.mounted) Navigator.pop(context);
                    await _load();
                  }
                },
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Cambiar objetivo de esta fecha'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dayInfo(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Color(0xff8993a5), fontSize: 12)),
          const SizedBox(height: 3),
          Text(value,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        ],
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Calendario',
              style: TextStyle(fontWeight: FontWeight.w800)),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(17, 6, 17, 28),
                  children: [
                    _monthHeader(),
                    const SizedBox(height: 10),
                    _weekdayHeader(),
                    const SizedBox(height: 5),
                    _monthGrid(),
                    const SizedBox(height: 18),
                    _legend(),
                    const SizedBox(height: 20),
                    _monthSummary(),
                  ],
                ),
              ),
      );

  Widget _monthHeader() => Row(
        children: [
          IconButton.filledTonal(
            onPressed: () => _moveMonth(-1),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Expanded(
            child: Text(
              _monthLabel(),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
          IconButton.filledTonal(
            onPressed: () => _moveMonth(1),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      );

  Widget _weekdayHeader() => Row(
        children: List.generate(7, (index) {
          const labels = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
          final dayNumber = (_weekStartDay - 1 + index) % 7;
          return Expanded(
            child: Center(
              child: Text(
                labels[dayNumber],
                style: const TextStyle(
                  color: Color(0xff8993a5),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          );
        }),
      );

  Widget _monthGrid() => GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 42,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 7,
          mainAxisSpacing: 5,
          crossAxisSpacing: 3,
          childAspectRatio: 0.76,
        ),
        itemBuilder: (context, index) {
          final date = _gridStart.add(Duration(days: index));
          final inMonth = date.month == _month.month;
          final today = dateKey(date) == dateKey(DateTime.now());
          final worked = _worked(date);
          final target = _target(date);
          final kind = _kinds[dateKey(date)] ?? DayKind.work;
          final hasOverride = _overrides.containsKey(dateKey(date));
          final hasNote = (_notes[dateKey(date)] ?? '').isNotEmpty;
          final hasAttachments = (_attachmentCounts[dateKey(date)] ?? 0) > 0;
          final progress =
              target == 0 ? 0.0 : (worked / target).clamp(0.0, 1.0);
          return Opacity(
            opacity: inMonth ? 1 : 0.35,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _openDay(date),
              child: Container(
                decoration: BoxDecoration(
                  color: today ? const Color(0xffeaf0ff) : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: today
                        ? const Color(0xff3978f6)
                        : const Color(0xffe8ebf1),
                    width: today ? 1.5 : 0.8,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('${date.day}',
                        style: TextStyle(
                            fontWeight: today ? FontWeight.w800 : FontWeight.w600,
                            fontSize: 12,
                            color: const Color(0xff263047))),
                    const SizedBox(height: 5),
                    if (kind != DayKind.work)
                      Text(kind.emoji, style: const TextStyle(fontSize: 11))
                    else
                      SizedBox(
                        width: 20,
                        height: 3,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: progress,
                            backgroundColor: target > 0
                                ? const Color(0xffe7ebf2)
                                : Colors.transparent,
                            valueColor: const AlwaysStoppedAnimation(
                                Color(0xff3978f6)),
                          ),
                        ),
                      ),
                    if (worked > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          '${worked ~/ 60}h',
                          style: const TextStyle(
                              fontSize: 8, color: Color(0xff66728a)),
                        ),
                      )
                    else if (hasOverride)
                      const Padding(
                        padding: EdgeInsets.only(top: 3),
                        child: Icon(Icons.flag_rounded,
                            size: 8, color: Color(0xff3978f6)),
                      ),
                    if (hasNote || hasAttachments)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (hasNote)
                              const Icon(Icons.notes_rounded,
                                  size: 8, color: Color(0xff8264d8)),
                            if (hasNote && hasAttachments)
                              const SizedBox(width: 2),
                            if (hasAttachments)
                              const Icon(Icons.attach_file_rounded,
                                  size: 8, color: Color(0xff3978f6)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );

  Widget _legend() => Wrap(
        spacing: 15,
        runSpacing: 8,
        children: [
          _legendItem(const Color(0xff3978f6), 'Horas registradas'),
          _legendItem(const Color(0xffdce4f1), 'Objetivo'),
          const Text('🏖️ Ausencia',
              style: TextStyle(fontSize: 11, color: Color(0xff788397))),
        ],
      );

  Widget _legendItem(Color color, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(fontSize: 11, color: Color(0xff788397))),
        ],
      );

  Widget _monthSummary() {
    final from = DateTime(_month.year, _month.month);
    final to = DateTime(_month.year, _month.month + 1, 0);
    var worked = 0;
    var target = 0;
    for (var date = from; !date.isAfter(to); date = date.add(const Duration(days: 1))) {
      worked += _worked(date);
      target += _target(date);
    }
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(19)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(child: _dayInfo('Trabajadas este mes', formatMinutes(worked))),
            Expanded(child: _dayInfo('Objetivo ajustado', formatMinutes(target))),
          ],
        ),
      ),
    );
  }

  String _monthLabel() {
    const months = [
      'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'
    ];
    final name = months[_month.month - 1];
    return '${name[0].toUpperCase()}${name.substring(1)} ${_month.year}';
  }

  String _dateTitle(DateTime date) {
    const months = [
      'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'
    ];
    return '${date.day} de ${months[date.month - 1]} de ${date.year}';
  }
}
