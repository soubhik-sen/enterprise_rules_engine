import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_theme.dart';
import 'api_client.dart';
import 'models.dart';
import 'providers.dart';

class Simulator extends ConsumerStatefulWidget {
  const Simulator({super.key});

  @override
  ConsumerState<Simulator> createState() => _SimulatorState();
}

class _SimulatorState extends ConsumerState<Simulator> {
  final Map<String, dynamic> _testInputs = {};
  final List<String> _logs = ['Engine initialized...'];
  bool _isLoading = false;
  bool _detailedMode = false;
  int _simulationCount = 0;
  final Map<String, String> _inputErrors = {};

  Future<void> _runSimulation() async {
    final currentSimId = ++_simulationCount;
    setState(() => _isLoading = true);
    final draft = ref.read(draftTableProvider);
    if (!_validateInputs(draft)) {
      _appendLog('Validation error: fix highlighted inputs before running.');
      ref.read(simulationResultProvider.notifier).state = SimulationResult(
        error: 'Input validation failed. Fix highlighted fields and retry.',
      );
      setState(() => _isLoading = false);
      return;
    }
    final context = <String, dynamic>{};
    for (final entry in draft.inputSchema) {
      if (_testInputs.containsKey(entry.key)) {
        context[entry.key] = _testInputs[entry.key];
      }
    }
    final hasUnsavedChanges = ref.read(hasUnsavedChangesProvider);
    final canEvaluatePersisted = !hasUnsavedChanges && draft.backendId != null;

    _appendLog(canEvaluatePersisted
        ? 'Running persisted evaluation for ${draft.slug}'
        : 'Running draft simulation for ${draft.slug}');

    for (var rule in draft.rules) {
      for (var entry in rule.inputs.entries) {
        final val = entry.value.toString();
        if (val.contains('..')) {
          final parts = val.split('..');
          if (parts.length == 2) {
            final start = double.tryParse(parts[0].trim());
            final end = double.tryParse(parts[1].trim());
            if (start != null && end != null && start > end) {
              final err =
                  'Validation Error in Rule #${rule.priority + 1}: Range $val is invalid.';
              _appendLog(err);
              ref.read(simulationResultProvider.notifier).state =
                  SimulationResult(error: err);
              setState(() => _isLoading = false);
              return;
            }
          }
        }
      }
    }

    try {
      final api = ref.read(apiClientProvider);
      final EvalResponse response;
      if (canEvaluatePersisted) {
        response = await api
            .evaluatePersisted(
              slug: draft.slug,
              context: context,
              detailed: _detailedMode,
            )
            .timeout(const Duration(seconds: 5));
      } else {
        response = await api
            .simulateDraft(
              draft: draft,
              context: context,
              detailed: _detailedMode,
            )
            .timeout(const Duration(seconds: 5));
      }

      if (currentSimId != _simulationCount) return;
      final resolvedMatchedRuleIds = _resolveMatchedRuleIds(
        response.matchedRuleIds,
        draft,
        canEvaluatePersisted,
      );
      final resolvedTrace = _resolveTraceRows(
        response.trace,
        draft,
        canEvaluatePersisted,
      );

      if (response.error != null && response.error!.isNotEmpty) {
        _appendLog('Simulation error: ${response.error!}');
        _appendDetailedTrace(resolvedTrace);
        ref.read(simulationResultProvider.notifier).state = SimulationResult(
          error: response.error,
          matchedRuleIds: resolvedMatchedRuleIds,
          trace: resolvedTrace,
        );
      } else {
        _appendLog(
            'Simulation completed. Matches: ${response.matchedRuleIds.length}');
        _appendDetailedTrace(resolvedTrace);
        ref.read(simulationResultProvider.notifier).state = SimulationResult(
          result: response.result,
          matchedRuleIds: resolvedMatchedRuleIds,
          trace: resolvedTrace,
        );
      }
    } on ApiException catch (e) {
      if (currentSimId != _simulationCount) return;
      _appendLog('Network error: ${e.message}');
      ref.read(simulationResultProvider.notifier).state = SimulationResult(
        error: e.message,
      );
    } catch (_) {
      if (currentSimId != _simulationCount) return;
      _appendLog('Connection failed');
      ref.read(simulationResultProvider.notifier).state = SimulationResult(
        error: 'Connection Failed: Is backend running?',
      );
    } finally {
      if (currentSimId == _simulationCount) {
        setState(() => _isLoading = false);
      }
    }
  }

  bool _validateInputs(RuleTable draft) {
    final errors = <String, String>{};
    for (final entry in draft.inputSchema) {
      if (!_testInputs.containsKey(entry.key)) {
        continue;
      }
      final value = _testInputs[entry.key];
      final error = _validateValueForType(entry, value);
      if (error != null) {
        errors[entry.key] = error;
      }
    }
    setState(() {
      _inputErrors
        ..clear()
        ..addAll(errors);
    });
    return errors.isEmpty;
  }

  void _validateSingleInput(SchemaEntry entry, dynamic value) {
    final error = value == null ? null : _validateValueForType(entry, value);
    setState(() {
      if (error == null) {
        _inputErrors.remove(entry.key);
      } else {
        _inputErrors[entry.key] = error;
      }
    });
  }

  String? _validateValueForType(SchemaEntry entry, dynamic value) {
    switch (entry.type) {
      case DataType.boolean:
        return value is bool ? null : 'Expected boolean';
      case DataType.number:
        if (value is num) {
          if (value % 1 != 0) {
            return 'Expected integer';
          }
          return null;
        }
        return 'Expected integer';
      case DataType.decimal:
        return value is num ? null : 'Expected decimal';
      case DataType.string:
        return value is String ? null : 'Expected string';
    }
  }

  void _appendLog(String message) {
    final ts = TimeOfDay.now();
    final stamp =
        '[${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}]';
    setState(() {
      _logs.insert(0, '$stamp $message');
      if (_logs.length > 20) {
        _logs.removeRange(20, _logs.length);
      }
    });
  }

  List<String> _resolveMatchedRuleIds(
    List<String> responseIds,
    RuleTable draft,
    bool fromPersistedEval,
  ) {
    if (!fromPersistedEval) return responseIds;
    final backendToLocal = <String, String>{};
    for (final rule in draft.rules) {
      if (rule.backendId != null) {
        backendToLocal[rule.backendId!] = rule.id;
      }
    }
    return responseIds.map((id) => backendToLocal[id] ?? id).toList();
  }

  List<Map<String, dynamic>> _resolveTraceRows(
    List<Map<String, dynamic>> trace,
    RuleTable draft,
    bool fromPersistedEval,
  ) {
    if (trace.isEmpty) return const [];
    if (!fromPersistedEval) {
      return trace
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
    }

    final backendToLocal = <String, String>{};
    for (final rule in draft.rules) {
      if (rule.backendId != null) {
        backendToLocal[rule.backendId!] = rule.id;
      }
    }

    return trace.map((item) {
      final map = Map<String, dynamic>.from(item);
      final rawRuleId = map['rule_id']?.toString();
      if (rawRuleId != null && rawRuleId.isNotEmpty) {
        map['rule_id'] = backendToLocal[rawRuleId] ?? rawRuleId;
      }
      return map;
    }).toList(growable: false);
  }

  void _appendDetailedTrace(List<Map<String, dynamic>> trace) {
    if (!_detailedMode || trace.isEmpty) return;
    for (final item in trace) {
      final ruleId = (item['rule_id'] ?? '').toString();
      final matched = item['matched'] == true;
      final priority = item['priority'] ?? '?';
      if (matched) {
        _appendLog('Trace row $priority [$ruleId]: matched');
        continue;
      }
      final failed =
          List<dynamic>.from(item['failed_fields'] as List? ?? const []);
      if (failed.isEmpty) {
        _appendLog('Trace row $priority [$ruleId]: no match');
        continue;
      }
      for (final failedItem in failed) {
        final failure = Map<String, dynamic>.from(failedItem as Map);
        final field = (failure['field'] ?? '').toString();
        final condition = (failure['condition'] ?? '').toString();
        final actual = failure['actual'];
        final reason = (failure['reason'] ?? '').toString();
        _appendLog(
          'Trace row $priority [$ruleId]: failed on "$field" condition "$condition" with value "$actual" ($reason)',
        );
      }
      _appendLog(
        'Trace row $priority [$ruleId]: moving to next row',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(draftTableProvider);
    final result = ref.watch(simulationResultProvider);

    return Column(
      children: [
        Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: const Row(
            children: [
              Icon(Icons.psychology_alt_outlined,
                  color: AppTheme.accent, size: 18),
              SizedBox(width: 10),
              Text(
                'Test Bench',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF131F47),
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: AppTheme.border),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ready for simulation',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 11),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Adjust input parameters below to see how rules resolve in real-time.',
                      style: TextStyle(fontSize: 10, color: AppTheme.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF101C42),
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Detailed simulation log',
                        style:
                            TextStyle(fontSize: 10, color: AppTheme.textMuted),
                      ),
                    ),
                    Switch(
                      value: _detailedMode,
                      onChanged: (value) {
                        setState(() => _detailedMode = value);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              ...draft.inputSchema.map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _TestInput(
                    key: ValueKey(entry.id),
                    entry: entry,
                    errorText: _inputErrors[entry.key],
                    onChanged: (val) {
                      if (val == null) {
                        _testInputs.remove(entry.key);
                      } else {
                        _testInputs[entry.key] = val;
                      }
                      _validateSingleInput(entry, val);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 6),
              ElevatedButton(
                onPressed:
                    (_isLoading || draft.rules.isEmpty) ? null : _runSimulation,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 44),
                  backgroundColor: AppTheme.accent,
                  foregroundColor: Colors.white,
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'RUN SIMULATION',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          fontSize: 10,
                        ),
                      ),
              ),
              const SizedBox(height: 18),
              if (result != null) _ResultDisplay(result: result, draft: draft),
              const SizedBox(height: 18),
              const Divider(),
              const SizedBox(height: 12),
              const Text(
                'SIMULATION LOG',
                style: TextStyle(
                  color: AppTheme.textMuted,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF040A1C),
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _logs
                      .map(
                        (line) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            line,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              color: AppTheme.statusMatched,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TestInput extends StatelessWidget {
  final SchemaEntry entry;
  final ValueChanged<dynamic> onChanged;
  final String? errorText;

  const _TestInput({
    super.key,
    required this.entry,
    required this.onChanged,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    final isDateField = _isDateLikeField(entry);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                entry.key.toUpperCase(),
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              _typeLabel(entry.type),
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
            ),
          ],
        ),
        const SizedBox(height: 7),
        if (entry.type == DataType.boolean)
          _BooleanSwitcher(onChanged: onChanged)
        else if (isDateField)
          _DateInputField(
            entry: entry,
            onChanged: onChanged,
            errorText: errorText,
          )
        else
          SizedBox(
            height: 32,
            child: TextField(
              keyboardType: (entry.type == DataType.number ||
                      entry.type == DataType.decimal)
                  ? TextInputType.number
                  : TextInputType.text,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                hintText: entry.type == DataType.number
                    ? 'Enter integer...'
                    : entry.type == DataType.decimal
                        ? 'Enter decimal...'
                        : 'Enter string...',
                hintStyle: const TextStyle(fontSize: 10),
                errorText: errorText,
                errorStyle: const TextStyle(
                  fontSize: 9,
                  color: AppTheme.statusInvalid,
                ),
              ),
              onChanged: (val) {
                final normalized = val.trim();
                if (normalized.isEmpty) {
                  onChanged(null);
                  return;
                }
                if (entry.type == DataType.number ||
                    entry.type == DataType.decimal) {
                  final parsed = num.tryParse(normalized);
                  onChanged(parsed ?? normalized);
                } else {
                  onChanged(val);
                }
              },
            ),
          ),
      ],
    );
  }

  bool _isDateLikeField(SchemaEntry entry) {
    if (entry.type != DataType.string) return false;
    final key = entry.key.trim().toLowerCase();
    return key.contains('date') ||
        key.contains('timestamp') ||
        key.endsWith('_dt') ||
        key.endsWith('_at') ||
        key.contains('eta') ||
        key.contains('etd');
  }

  String _typeLabel(DataType type) {
    switch (type) {
      case DataType.boolean:
        return 'Boolean';
      case DataType.number:
        return 'Integer';
      case DataType.decimal:
        return 'Decimal';
      case DataType.string:
        return 'String';
    }
  }
}

class _DateInputField extends StatefulWidget {
  final SchemaEntry entry;
  final ValueChanged<dynamic> onChanged;
  final String? errorText;

  const _DateInputField({
    required this.entry,
    required this.onChanged,
    this.errorText,
  });

  @override
  State<_DateInputField> createState() => _DateInputFieldState();
}

class _DateInputFieldState extends State<_DateInputField> {
  DateTime? _selectedDate;
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final initial = _selectedDate ?? DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900, 1, 1),
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedDate = DateTime(picked.year, picked.month, picked.day);
      _controller.text = _formatDate(_selectedDate!);
    });
    widget.onChanged(_controller.text);
  }

  void _clearDate() {
    setState(() {
      _selectedDate = null;
      _controller.clear();
    });
    widget.onChanged(null);
  }

  String _formatDate(DateTime value) {
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: TextField(
        controller: _controller,
        readOnly: true,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          hintText: 'Select date...',
          hintStyle: const TextStyle(fontSize: 10),
          errorText: widget.errorText,
          errorStyle: const TextStyle(
            fontSize: 9,
            color: AppTheme.statusInvalid,
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 52,
            maxWidth: 52,
            minHeight: 22,
            maxHeight: 22,
          ),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_controller.text.isNotEmpty)
                InkWell(
                  onTap: _clearDate,
                  child: const Icon(
                    Icons.clear,
                    size: 13,
                    color: AppTheme.textMuted,
                  ),
                ),
              const SizedBox(width: 6),
              InkWell(
                onTap: _pickDate,
                child: const Icon(
                  Icons.calendar_today,
                  size: 13,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ),
        onTap: _pickDate,
      ),
    );
  }
}

class _BooleanSwitcher extends StatefulWidget {
  final ValueChanged<dynamic> onChanged;
  const _BooleanSwitcher({required this.onChanged});

  @override
  State<_BooleanSwitcher> createState() => _BooleanSwitcherState();
}

class _BooleanSwitcherState extends State<_BooleanSwitcher> {
  bool? value;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: AppTheme.panelSoft,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () {
                setState(() => value = true);
                widget.onChanged(true);
              },
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: value == true ? AppTheme.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: const Text(
                  'True',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 10),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () {
                setState(() => value = false);
                widget.onChanged(false);
              },
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: value == false ? AppTheme.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: const Text(
                  'False',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultDisplay extends StatelessWidget {
  final SimulationResult result;
  final RuleTable draft;
  const _ResultDisplay({required this.result, required this.draft});

  @override
  Widget build(BuildContext context) {
    final isError = result.error != null;
    final hasMatches = result.matchedRuleIds.isNotEmpty;
    final hasTrace = result.trace.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isError ? AppTheme.statusInvalidBg : const Color(0xFF101D3E),
            borderRadius: BorderRadius.circular(2),
            border: Border.all(
              color: isError ? AppTheme.statusInvalid : AppTheme.border,
            ),
          ),
          child: isError
              ? Text(result.error!,
                  style: const TextStyle(color: AppTheme.statusInvalid))
              : SelectableText(
                  const JsonEncoder.withIndent('  ').convert(result.result),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
        ),
        if (hasMatches) ...[
          const SizedBox(height: 10),
          _MatchedRulesPanel(
            matchedRuleIds: result.matchedRuleIds,
            draft: draft,
          ),
        ],
        if (hasTrace) ...[
          const SizedBox(height: 10),
          _TraceExplainPanel(
            trace: result.trace,
            draft: draft,
          ),
        ],
      ],
    );
  }
}

class _TraceExplainPanel extends StatelessWidget {
  final List<Map<String, dynamic>> trace;
  final RuleTable draft;

  const _TraceExplainPanel({
    required this.trace,
    required this.draft,
  });

  Rule? _findRule(String ruleId) {
    for (final rule in draft.rules) {
      if (rule.id == ruleId || rule.backendId == ruleId) {
        return rule;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      collapsedBackgroundColor: const Color(0xFF0F1A36),
      backgroundColor: const Color(0xFF0F1A36),
      title: Text(
        'Why matched / why not (${trace.length} rows)',
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
      children: [
        for (final row in trace) _buildTraceRow(row),
      ],
    );
  }

  Widget _buildTraceRow(Map<String, dynamic> row) {
    final ruleId = (row['rule_id'] ?? '').toString();
    final matched = row['matched'] == true;
    final priority = row['priority'];
    final rule = _findRule(ruleId);
    final displayRow =
        priority ?? (rule != null ? (rule.priority + 1).toString() : '?');
    final failed =
        List<dynamic>.from(row['failed_fields'] as List? ?? const []);

    final statusColor =
        matched ? AppTheme.statusMatched : AppTheme.statusInvalid;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0B1430),
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Rule #$displayRow',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: statusColor),
                  ),
                  child: Text(
                    matched ? 'MATCHED' : 'NOT MATCHED',
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 9,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ),
            if (!matched && failed.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final item in failed) _buildFailedField(item),
            ],
            if (matched && failed.isEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                'All input conditions passed for this row.',
                style: TextStyle(
                  fontSize: 10,
                  color: AppTheme.statusMatched,
                ),
              ),
            ],
            if (!matched && failed.isEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                'No field-level details were returned by the engine.',
                style: TextStyle(
                  fontSize: 10,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFailedField(dynamic raw) {
    final item = Map<String, dynamic>.from(raw as Map);
    final field = (item['field'] ?? '').toString();
    final condition = (item['condition'] ?? '').toString();
    final actual = item['actual'];
    final reason = (item['reason'] ?? '').toString();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppTheme.statusInvalidBg.withOpacity(0.45),
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: AppTheme.statusInvalid.withOpacity(0.7)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              field.isEmpty ? 'Field check failed' : field,
              style: const TextStyle(
                color: AppTheme.statusInvalid,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Condition: $condition | Actual: $actual',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: AppTheme.textMuted,
              ),
            ),
            if (reason.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                reason,
                style: const TextStyle(
                  fontSize: 10,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MatchedRulesPanel extends StatelessWidget {
  final List<String> matchedRuleIds;
  final RuleTable draft;

  const _MatchedRulesPanel({
    required this.matchedRuleIds,
    required this.draft,
  });

  Rule? _findRule(String ruleId) {
    for (final rule in draft.rules) {
      if (rule.id == ruleId || rule.backendId == ruleId) {
        return rule;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final matched =
        matchedRuleIds.map(_findRule).whereType<Rule>().toList(growable: false);
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      collapsedBackgroundColor: const Color(0xFF0F1A36),
      backgroundColor: const Color(0xFF0F1A36),
      title: Text(
        'Matched rules (${matched.length})',
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
      children: matched
          .map(
            (rule) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B1430),
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Rule #${rule.priority + 1}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Inputs: ${jsonEncode(rule.inputs)}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: AppTheme.textMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Outputs: ${jsonEncode(rule.outputs)}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}
