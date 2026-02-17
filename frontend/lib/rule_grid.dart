import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'app_theme.dart';
import 'models.dart';
import 'providers.dart';

class RuleGrid extends ConsumerStatefulWidget {
  const RuleGrid({super.key});

  @override
  ConsumerState<RuleGrid> createState() => _RuleGridState();
}

class _RuleGridState extends ConsumerState<RuleGrid> {
  PlutoGridStateManager? stateManager;
  Timer? _debounce;
  String? _lastSelectedField;
  int? _lastSelectedRowIdx;
  static const Set<String> _numericTokens = {'>', '>=', '<', '<=', '..'};
  _DiffSummary? _diffSnapshot;
  bool _diffStale = false;
  int _diffRenderVersion = 0;
  _ConflictAnalysisResult? _conflictSnapshot;
  bool _conflictStale = false;
  final Map<String, int> _flashTokens = {};
  final Map<String, String> _invalidCellMessages = {};
  Timer? _flashTimer;
  String _lastStructureFingerprint = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _flashTimer?.cancel();
    super.dispose();
  }

  void _onChanged(PlutoGridOnChangedEvent event) {
    _validateChangedCell(event);

    if (_debounce?.isActive ?? false) _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _updateDraftFromGrid();
    });
    if (_diffSnapshot != null || _conflictSnapshot != null) {
      setState(() {
        if (_diffSnapshot != null) _diffStale = true;
        if (_conflictSnapshot != null) _conflictStale = true;
      });
    }
  }

  void _validateChangedCell(PlutoGridOnChangedEvent event) {
    final rawValue = event.value?.toString() ?? '';
    final field = event.column.field;
    final rowKey = event.row.key as ValueKey<String>?;
    if (rowKey == null) return;
    final cellKey = '${rowKey.value}::$field';
    String? error;

    final draft = ref.read(draftTableProvider);
    SchemaEntry? inputEntry;
    for (final entry in draft.inputSchema) {
      if (entry.key == field) {
        inputEntry = entry;
        break;
      }
    }
    final isNumericInput = inputEntry != null &&
        (inputEntry.type == DataType.number ||
            inputEntry.type == DataType.decimal);

    if (!isNumericInput) {
      final existing = _invalidCellMessages[cellKey];
      if (existing != null) {
        setState(() => _invalidCellMessages.remove(cellKey));
      }
      return;
    }

    if (rawValue.contains('..')) {
      final parts = rawValue.split('..');
      if (parts.length == 2) {
        final start = double.tryParse(parts[0].trim());
        final end = double.tryParse(parts[1].trim());
        if (start != null && end != null && start > end) {
          error = 'Invalid range: start cannot be greater than end.';
        }
      }
    }

    final current = _invalidCellMessages[cellKey];
    if (error == null && current == null) return;
    if (error == current) return;
    setState(() {
      if (error == null) {
        _invalidCellMessages.remove(cellKey);
      } else {
        _invalidCellMessages[cellKey] = error;
      }
    });
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error),
          backgroundColor: AppTheme.statusInvalid,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _updateDraftFromGrid() {
    if (stateManager == null) return;

    final draft = ref.read(draftTableProvider);
    final existingByLocalId = {for (final rule in draft.rules) rule.id: rule};
    final List<Rule> updatedRules = [];

    for (var row in stateManager!.rows) {
      final Map<String, dynamic> inputs = {};
      final Map<String, dynamic> outputs = {};

      for (var entry in draft.inputSchema) {
        inputs[entry.key] = row.cells[entry.key]?.value;
      }
      for (var entry in draft.outputSchema) {
        outputs[entry.key] = row.cells[entry.key]?.value;
      }

      final rowKey = row.key as ValueKey<String>?;
      final localId = rowKey?.value ?? 'row_${stateManager!.rows.indexOf(row)}';
      final existing = existingByLocalId[localId];
      updatedRules.add(Rule(
        id: localId,
        backendId: existing?.backendId,
        inputs: inputs,
        outputs: outputs,
        priority: stateManager!.rows.indexOf(row),
      ));
    }

    final updatedDraft = draft.copyWith(rules: updatedRules);
    ref.read(draftTableProvider.notifier).state = updatedDraft;
    _pruneInvalidCellMessages(updatedDraft);
  }

  void _captureDiffSnapshot() {
    if (_debounce?.isActive ?? false) {
      _debounce?.cancel();
    }
    _updateDraftFromGrid();
    final latestPersisted = ref.read(persistedTableProvider);
    final latestDraft = ref.read(draftTableProvider);
    setState(() {
      _diffSnapshot = _buildDiffSummary(latestPersisted, latestDraft);
      _diffStale = false;
      _diffRenderVersion += 1;
    });
  }

  void _captureConflictSnapshot() {
    if (_debounce?.isActive ?? false) {
      _debounce?.cancel();
    }
    _updateDraftFromGrid();
    final latestDraft = ref.read(draftTableProvider);
    setState(() {
      _conflictSnapshot = _analyzeConflicts(latestDraft);
      _conflictStale = false;
    });
  }

  void _applyConflictFix(_ConflictFinding finding) {
    final draft = ref.read(draftTableProvider);
    if (finding.fix == _ConflictFix.none) {
      return;
    }

    var updatedRules = List<Rule>.from(draft.rules);
    switch (finding.fix) {
      case _ConflictFix.removeRule:
        updatedRules.removeWhere((rule) => rule.id == finding.laterRuleId);
        break;
      case _ConflictFix.moveBefore:
        final laterIndex =
            updatedRules.indexWhere((rule) => rule.id == finding.laterRuleId);
        final earlierIndex =
            updatedRules.indexWhere((rule) => rule.id == finding.earlierRuleId);
        if (laterIndex < 0 || earlierIndex < 0 || laterIndex <= earlierIndex) {
          return;
        }
        final moving = updatedRules.removeAt(laterIndex);
        final targetIndex =
            updatedRules.indexWhere((rule) => rule.id == finding.earlierRuleId);
        if (targetIndex < 0) {
          updatedRules.add(moving);
        } else {
          updatedRules.insert(targetIndex, moving);
        }
        break;
      case _ConflictFix.none:
        return;
    }

    updatedRules = [
      for (var i = 0; i < updatedRules.length; i++)
        updatedRules[i].copyWith(priority: i),
    ];
    final updatedDraft = draft.copyWith(rules: updatedRules);
    ref.read(draftTableProvider.notifier).state = updatedDraft;
    setState(() {
      _conflictSnapshot = _analyzeConflicts(updatedDraft);
      _conflictStale = false;
      _diffStale = true;
      _diffRenderVersion += 1;
      _lastStructureFingerprint = _computeStructureFingerprint(updatedDraft);
    });
  }

  void _pruneInvalidCellMessages(
    RuleTable draft, {
    bool notify = true,
  }) {
    if (_invalidCellMessages.isEmpty) return;
    final validRuleIds = draft.rules.map((rule) => rule.id).toSet();
    final validNumericInputFields = draft.inputSchema
        .where((entry) =>
            entry.type == DataType.number || entry.type == DataType.decimal)
        .map((entry) => entry.key)
        .toSet();

    final staleKeys = <String>[];
    for (final key in _invalidCellMessages.keys) {
      final parts = key.split('::');
      if (parts.length != 2) {
        staleKeys.add(key);
        continue;
      }
      final rowId = parts[0];
      final field = parts[1];
      if (!validRuleIds.contains(rowId) ||
          !validNumericInputFields.contains(field)) {
        staleKeys.add(key);
      }
    }
    if (staleKeys.isEmpty) return;
    if (notify) {
      setState(() {
        for (final key in staleKeys) {
          _invalidCellMessages.remove(key);
        }
      });
      return;
    }
    for (final key in staleKeys) {
      _invalidCellMessages.remove(key);
    }
  }

  void _syncStructureState({
    required RuleTable draft,
    required bool hasRows,
    required String structureFingerprint,
  }) {
    final structureChanged = _lastStructureFingerprint != structureFingerprint;
    _lastStructureFingerprint = structureFingerprint;
    if (structureChanged) {
      _pruneInvalidCellMessages(draft, notify: false);
      if (_diffSnapshot != null) {
        _diffSnapshot = null;
        _diffStale = false;
        _diffRenderVersion += 1;
      }
      if (_conflictSnapshot != null) {
        _conflictStale = true;
      }
    }
    if (!hasRows && _diffSnapshot != null) {
      _diffSnapshot = null;
      _diffStale = false;
      _diffRenderVersion += 1;
    }
    if (!hasRows && _conflictSnapshot != null) {
      _conflictSnapshot = null;
      _conflictStale = false;
    }
  }

  String _computeStructureFingerprint(RuleTable draft) {
    final schemaSignature = [
      ...draft.inputSchema.map((e) => 'in:${e.id}:${e.key}:${e.type.name}'),
      ...draft.outputSchema.map((e) => 'out:${e.id}:${e.key}:${e.type.name}'),
    ].join('|');
    return '${draft.id}|$schemaSignature|${draft.rules.map((r) => r.id).join(',')}';
  }

  void _insertOperatorToken(String token) {
    if (stateManager == null) return;

    final draft = ref.read(draftTableProvider);
    PlutoColumn? currentColumn = stateManager!.currentColumn;
    PlutoCell? currentCell = stateManager!.currentCell;

    if ((currentColumn == null || currentCell == null) &&
        _lastSelectedField != null &&
        _lastSelectedRowIdx != null &&
        _lastSelectedRowIdx! >= 0 &&
        _lastSelectedRowIdx! < stateManager!.rows.length) {
      final row = stateManager!.rows[_lastSelectedRowIdx!];
      currentColumn = stateManager!.refColumns.firstWhere(
        (c) => c.field == _lastSelectedField,
        orElse: () => stateManager!.refColumns.first,
      );
      currentCell = row.cells[_lastSelectedField!];
      if (currentCell != null) {
        stateManager!.setCurrentCell(currentCell, _lastSelectedRowIdx!);
      }
    }

    if (currentColumn == null || currentCell == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select an input cell first.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final selectedField = currentColumn.field;
    final isInputColumn = draft.inputSchema.any((e) => e.key == selectedField);
    if (!isInputColumn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Operator shortcuts apply only to input condition cells.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final inputEntry =
        draft.inputSchema.firstWhere((e) => e.key == selectedField);
    final fieldType = inputEntry.type;
    if (_numericTokens.contains(token) &&
        !(fieldType == DataType.number || fieldType == DataType.decimal)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Numeric operators are allowed only for number/decimal input fields.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (token == 'CP' && fieldType != DataType.string) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('CP pattern operator is allowed only for string fields.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final existing = currentCell.value?.toString() ?? '';
    final updated = _applyToken(existing, token);
    stateManager!.changeCellValue(
      currentCell,
      updated,
      callOnChangedEvent: true,
      force: true,
    );
    _updateDraftFromGrid();
  }

  String _applyToken(String existing, String token) {
    final trimmed = existing.trim();
    if (token == 'IN (...)') {
      return trimmed.isEmpty ? "IN ('A', 'B')" : existing;
    }
    if (token == 'CP') {
      if (trimmed.isEmpty) return 'CP *pattern*';
      if (trimmed.toUpperCase().startsWith('CP ')) return existing;
      return 'CP $trimmed';
    }
    if (token == '..') {
      if (trimmed.isEmpty) return '0..100';
      final parsed = num.tryParse(trimmed);
      if (parsed != null) return '0..$trimmed';
      return '0..100';
    }
    if (trimmed.isEmpty) {
      return '$token 0';
    }
    final comparatorPattern = RegExp(r'^(>=|<=|>|<)\s*(.+)$');
    final existingMatch = comparatorPattern.firstMatch(trimmed);
    if (existingMatch != null) {
      final rhs = existingMatch.group(2)!.trim();
      return '$token $rhs';
    }
    return '$token $trimmed';
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(draftTableProvider);
    final simulationResult = ref.watch(simulationResultProvider);
    final hasRows = draft.rules.isNotEmpty;
    final schemaSignature = [
      ...draft.inputSchema.map((e) => 'in:${e.id}:${e.key}:${e.type.name}'),
      ...draft.outputSchema.map((e) => 'out:${e.id}:${e.key}:${e.type.name}'),
    ].join('|');
    final rulesSignature =
        draft.rules.map((r) => '${r.id}:${r.priority}').join('|');
    final structureFingerprint = _computeStructureFingerprint(draft);
    _syncStructureState(
      draft: draft,
      hasRows: hasRows,
      structureFingerprint: structureFingerprint,
    );
    final diffSummary = _diffSnapshot;
    final conflictSummary = _conflictSnapshot;

    final List<PlutoColumn> columns = [
      PlutoColumn(
        title: '#',
        field: 'priority',
        type: PlutoColumnType.number(),
        width: 35,
        enableEditingMode: false,
        titleTextAlign: PlutoColumnTextAlign.left,
      ),
    ];

    // Input Columns
    for (var entry in draft.inputSchema) {
      columns.add(PlutoColumn(
        title: '${entry.key} (IN)',
        field: entry.key,
        type: PlutoColumnType.text(),
        width: 138,
        backgroundColor: const Color(0xFF0E1A3C),
        renderer: (rendererContext) => _buildCellRenderer(
          rendererContext,
          diffSummary,
          _flashTokens,
          _invalidCellMessages,
          isOutput: false,
        ),
      ));
    }

    // Output Columns
    for (var entry in draft.outputSchema) {
      columns.add(PlutoColumn(
        title: '${entry.key} (OUT)',
        titleSpan: TextSpan(
          text: '${entry.key} (OUT)',
          style: const TextStyle(
            color: Color(0xFF67E7A0),
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            fontSize: 9,
          ),
        ),
        field: entry.key,
        type: _getOutputPlutoType(entry.type),
        width: 138,
        backgroundColor: const Color(0xFF0F2A23),
        renderer: (rendererContext) {
          return _buildCellRenderer(
            rendererContext,
            diffSummary,
            _flashTokens,
            _invalidCellMessages,
            isOutput: true,
          );
        },
      ));
    }

    final List<PlutoRow> rows = draft.rules.map((rule) {
      final Map<String, PlutoCell> cells = {
        'priority': PlutoCell(value: rule.priority + 1),
      };

      for (var entry in draft.inputSchema) {
        cells[entry.key] = PlutoCell(value: rule.inputs[entry.key]);
      }
      for (var entry in draft.outputSchema) {
        cells[entry.key] = PlutoCell(value: rule.outputs[entry.key]);
      }

      return PlutoRow(cells: cells, key: ValueKey(rule.id));
    }).toList();

    return Column(
      children: [
        if (hasRows)
          _ConflictAnalyzerPanel(
            result: conflictSummary,
            isStale: _conflictStale,
            onAnalyze: _captureConflictSnapshot,
            onRefresh: _captureConflictSnapshot,
            onClear: () {
              setState(() {
                _conflictSnapshot = null;
                _conflictStale = false;
              });
            },
            onApplyFix: _applyConflictFix,
          ),
        if (hasRows && diffSummary != null)
          _ChangeSummaryPanel(
            summary: diffSummary,
            onFocusCell: _focusCell,
            isStale: _diffStale,
            onRefresh: _captureDiffSnapshot,
            onClear: () {
              setState(() {
                _diffSnapshot = null;
                _diffStale = false;
                _diffRenderVersion += 1;
              });
            },
          ),
        if (hasRows && diffSummary == null)
          _DetectChangesBar(
            onDetect: _captureDiffSnapshot,
          ),
        Expanded(
          child: PlutoGrid(
            key: ValueKey(
                '${draft.id}|$schemaSignature|$rulesSignature|diffv:$_diffRenderVersion'),
            columns: columns,
            rows: rows,
            onChanged: _onChanged,
            onLoaded: (PlutoGridOnLoadedEvent event) {
              stateManager = event.stateManager;
              stateManager?.setSelectingMode(PlutoGridSelectingMode.cell);
            },
            onSelected: (PlutoGridOnSelectedEvent event) {
              _lastSelectedRowIdx = event.rowIdx;
              if (event.cell != null) {
                _lastSelectedField = stateManager?.currentColumn?.field;
              }
            },
            rowColorCallback: (rowContext) {
              if (simulationResult != null) {
                final rowKey = rowContext.row.key as ValueKey<String>?;
                if (rowKey != null &&
                    simulationResult.matchedRuleIds.contains(rowKey.value)) {
                  return AppTheme.statusMatchedBg;
                }
              }
              return AppTheme.bg;
            },
            configuration: PlutoGridConfiguration(
              columnSize: const PlutoGridColumnSizeConfig(
                autoSizeMode: PlutoAutoSizeMode.none,
                restoreAutoSizeAfterMoveColumn: false,
              ),
              style: PlutoGridStyleConfig(
                gridBackgroundColor: AppTheme.bg,
                rowColor: AppTheme.bg,
                evenRowColor: const Color(0xFF060D28),
                activatedColor: AppTheme.accentSoft.withOpacity(0.35),
                cellColorInEditState: const Color(0xFF0B1430),
                gridBorderColor: AppTheme.border,
                borderColor: AppTheme.border,
                activatedBorderColor: AppTheme.accent,
                inactivatedBorderColor: AppTheme.border,
                rowHeight: 34,
                columnHeight: 34,
                columnTextStyle: const TextStyle(
                  color: Color(0xFF88A1D7),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  fontSize: 9,
                ),
                cellTextStyle: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Color(0xFF6FB8FF),
                ),
              ),
            ),
            createFooter: (stateManager) {
              return Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: const BoxDecoration(
                  color: Color(0xFF0A1436),
                  border: Border(top: BorderSide(color: AppTheme.border)),
                ),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            if (_debounce?.isActive ?? false) {
                              _debounce?.cancel();
                            }
                            _updateDraftFromGrid();
                            final latestDraft = ref.read(draftTableProvider);
                            final newRule = Rule.create(
                              inputs: {
                                for (var e in latestDraft.inputSchema) e.key: ''
                              },
                              outputs: {
                                for (var e in latestDraft.outputSchema)
                                  e.key: ''
                              },
                              priority: latestDraft.rules.length,
                            );
                            ref.read(draftTableProvider.notifier).state =
                                latestDraft.copyWith(
                              rules: [...latestDraft.rules, newRule],
                            );
                            setState(() {
                              if (_diffSnapshot != null) _diffStale = true;
                              if (_conflictSnapshot != null) {
                                _conflictStale = true;
                              }
                            });
                          },
                          icon: const Icon(Icons.add_box_rounded, size: 15),
                          label: const Text('ADD RULE'),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF8BB8FF),
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.7,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'SHORTCUTS:',
                          style:
                              TextStyle(color: AppTheme.textMuted, fontSize: 9),
                        ),
                        const SizedBox(width: 8),
                        _OperatorChip(
                            label: '>', onTap: () => _insertOperatorToken('>')),
                        _OperatorChip(
                            label: '>=',
                            onTap: () => _insertOperatorToken('>=')),
                        _OperatorChip(
                            label: '<', onTap: () => _insertOperatorToken('<')),
                        _OperatorChip(
                            label: '<=',
                            onTap: () => _insertOperatorToken('<=')),
                        _OperatorChip(
                            label: '..',
                            onTap: () => _insertOperatorToken('..')),
                        _OperatorChip(
                            label: 'CP',
                            onTap: () => _insertOperatorToken('CP')),
                        _OperatorChip(
                            label: 'IN (...)',
                            onTap: () => _insertOperatorToken('IN (...)')),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _focusCell(String ruleId, String field) {
    if (stateManager == null) return;
    final rowIndex = stateManager!.rows.indexWhere((row) {
      final key = row.key as ValueKey<String>?;
      return key != null && key.value == ruleId;
    });
    if (rowIndex < 0) return;
    final row = stateManager!.rows[rowIndex];
    final cell = row.cells[field];
    if (cell == null) return;
    stateManager!.setCurrentCell(cell, rowIndex);
    _triggerFlash(ruleId, field);
  }

  void _triggerFlash(String ruleId, String field) {
    final key = '$ruleId::$field';
    setState(() {
      _flashTokens[key] = (_flashTokens[key] ?? 0) + 1;
    });
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() {
        _flashTokens.remove(key);
      });
    });
  }

  PlutoColumnType _getOutputPlutoType(DataType type) {
    switch (type) {
      case DataType.number:
      case DataType.decimal:
        return PlutoColumnType.number();
      case DataType.boolean:
        return PlutoColumnType.select(['true', 'false']);
      case DataType.string:
      default:
        return PlutoColumnType.text();
    }
  }
}

class _CellDiff {
  final String before;
  final String after;
  final bool isNewRow;

  const _CellDiff({
    required this.before,
    required this.after,
    required this.isNewRow,
  });
}

class _DiffItem {
  final String ruleId;
  final int rowNumber;
  final String field;
  final String before;
  final String after;
  final bool isOutput;
  final bool isNewRow;

  const _DiffItem({
    required this.ruleId,
    required this.rowNumber,
    required this.field,
    required this.before,
    required this.after,
    required this.isOutput,
    required this.isNewRow,
  });
}

class _RemovedRow {
  final String ruleId;
  final int rowNumber;

  const _RemovedRow({
    required this.ruleId,
    required this.rowNumber,
  });
}

class _DiffSummary {
  final Map<String, Map<String, _CellDiff>> cellDiffs;
  final List<_DiffItem> items;
  final List<_RemovedRow> removedRows;
  final int addedRows;

  const _DiffSummary({
    required this.cellDiffs,
    required this.items,
    required this.removedRows,
    required this.addedRows,
  });

  bool get hasChanges =>
      items.isNotEmpty || removedRows.isNotEmpty || addedRows > 0;
}

enum _ConflictType { overlap, shadowed, unreachable }

enum _ConflictFix { none, removeRule, moveBefore }

class _ConflictFinding {
  final _ConflictType type;
  final String message;
  final String earlierRuleId;
  final String laterRuleId;
  final int earlierRowNumber;
  final int laterRowNumber;
  final _ConflictFix fix;

  const _ConflictFinding({
    required this.type,
    required this.message,
    required this.earlierRuleId,
    required this.laterRuleId,
    required this.earlierRowNumber,
    required this.laterRowNumber,
    required this.fix,
  });
}

class _ConflictAnalysisResult {
  final List<_ConflictFinding> findings;

  const _ConflictAnalysisResult({
    required this.findings,
  });

  bool get hasFindings => findings.isNotEmpty;

  int get overlapCount =>
      findings.where((f) => f.type == _ConflictType.overlap).length;
  int get shadowedCount =>
      findings.where((f) => f.type == _ConflictType.shadowed).length;
  int get unreachableCount =>
      findings.where((f) => f.type == _ConflictType.unreachable).length;
}

enum _TruthState { yes, no, unknown }

enum _ConditionKind {
  wildcard,
  exactString,
  exactNumber,
  inSet,
  range,
  comparison,
  pattern,
}

class _ConditionSpec {
  final _ConditionKind kind;
  final String raw;
  final String? stringValue;
  final double? numberValue;
  final Set<String>? stringSet;
  final Set<double>? numberSet;
  final double? min;
  final double? max;
  final String? comparisonOp;
  final String? pattern;

  const _ConditionSpec({
    required this.kind,
    required this.raw,
    this.stringValue,
    this.numberValue,
    this.stringSet,
    this.numberSet,
    this.min,
    this.max,
    this.comparisonOp,
    this.pattern,
  });
}

class _NumericInterval {
  final double min;
  final double max;
  final bool minInclusive;
  final bool maxInclusive;

  const _NumericInterval({
    required this.min,
    required this.max,
    required this.minInclusive,
    required this.maxInclusive,
  });
}

_ConflictAnalysisResult _analyzeConflicts(RuleTable draft) {
  final rules = List<Rule>.from(draft.rules)
    ..sort((a, b) => a.priority.compareTo(b.priority));
  if (rules.length < 2) {
    return const _ConflictAnalysisResult(findings: []);
  }

  final findings = <_ConflictFinding>[];
  final firstHit = draft.hitPolicy.trim().toUpperCase() == 'FIRST_HIT';

  for (var laterIdx = 1; laterIdx < rules.length; laterIdx++) {
    final later = rules[laterIdx];
    bool blockedByEarlier = false;

    if (firstHit) {
      for (var earlierIdx = 0; earlierIdx < laterIdx; earlierIdx++) {
        final earlier = rules[earlierIdx];
        final coverage = _ruleCovers(
          earlier: earlier,
          later: later,
          schema: draft.inputSchema,
        );
        if (coverage != _TruthState.yes) {
          continue;
        }
        final sameInputs = _canonicalInputs(earlier, draft.inputSchema) ==
            _canonicalInputs(later, draft.inputSchema);
        final earlierSpecificity = _ruleSpecificity(earlier, draft.inputSchema);
        final laterSpecificity = _ruleSpecificity(later, draft.inputSchema);
        final unreachable = !sameInputs &&
            (_isWildcardRule(earlier, draft.inputSchema) ||
                earlierSpecificity < laterSpecificity);

        findings.add(
          _ConflictFinding(
            type: unreachable
                ? _ConflictType.unreachable
                : _ConflictType.shadowed,
            message: unreachable
                ? 'Rule ${later.priority + 1} is unreachable because Rule ${earlier.priority + 1} already covers its inputs.'
                : 'Rule ${later.priority + 1} is shadowed by Rule ${earlier.priority + 1}.',
            earlierRuleId: earlier.id,
            laterRuleId: later.id,
            earlierRowNumber: earlier.priority + 1,
            laterRowNumber: later.priority + 1,
            fix: _ConflictFix.removeRule,
          ),
        );
        blockedByEarlier = true;
        break;
      }
    }

    if (blockedByEarlier) {
      continue;
    }

    for (var earlierIdx = 0; earlierIdx < laterIdx; earlierIdx++) {
      final earlier = rules[earlierIdx];
      final overlap = _ruleOverlaps(
        a: earlier,
        b: later,
        schema: draft.inputSchema,
      );
      if (overlap != _TruthState.yes) {
        continue;
      }
      final earlierSpecificity = _ruleSpecificity(earlier, draft.inputSchema);
      final laterSpecificity = _ruleSpecificity(later, draft.inputSchema);
      final fix = firstHit && laterSpecificity > earlierSpecificity
          ? _ConflictFix.moveBefore
          : _ConflictFix.none;
      findings.add(
        _ConflictFinding(
          type: _ConflictType.overlap,
          message:
              'Rule ${earlier.priority + 1} and Rule ${later.priority + 1} overlap on input conditions.',
          earlierRuleId: earlier.id,
          laterRuleId: later.id,
          earlierRowNumber: earlier.priority + 1,
          laterRowNumber: later.priority + 1,
          fix: fix,
        ),
      );
      break;
    }
  }

  return _ConflictAnalysisResult(findings: findings);
}

String _canonicalInputs(Rule rule, List<SchemaEntry> schema) {
  final parts = <String>[];
  for (final entry in schema) {
    final value = (rule.inputs[entry.key] ?? '').toString().trim();
    parts.add('${entry.key}=$value');
  }
  return parts.join('|');
}

bool _isWildcardRule(Rule rule, List<SchemaEntry> schema) {
  for (final entry in schema) {
    final spec = _parseConditionSpec(rule.inputs[entry.key], entry.type);
    if (spec.kind != _ConditionKind.wildcard) {
      return false;
    }
  }
  return true;
}

int _ruleSpecificity(Rule rule, List<SchemaEntry> schema) {
  var score = 0;
  for (final entry in schema) {
    final spec = _parseConditionSpec(rule.inputs[entry.key], entry.type);
    switch (spec.kind) {
      case _ConditionKind.wildcard:
        score += 0;
        break;
      case _ConditionKind.exactString:
      case _ConditionKind.exactNumber:
        score += 4;
        break;
      case _ConditionKind.inSet:
        score += 3;
        break;
      case _ConditionKind.range:
      case _ConditionKind.comparison:
        score += 2;
        break;
      case _ConditionKind.pattern:
        score += 1;
        break;
    }
  }
  return score;
}

_TruthState _ruleCovers({
  required Rule earlier,
  required Rule later,
  required List<SchemaEntry> schema,
}) {
  var hasUnknown = false;
  for (final entry in schema) {
    final earlierSpec =
        _parseConditionSpec(earlier.inputs[entry.key], entry.type);
    final laterSpec = _parseConditionSpec(later.inputs[entry.key], entry.type);
    final state = _fieldCovers(earlierSpec, laterSpec, entry.type);
    if (state == _TruthState.no) {
      return _TruthState.no;
    }
    if (state == _TruthState.unknown) {
      hasUnknown = true;
    }
  }
  return hasUnknown ? _TruthState.unknown : _TruthState.yes;
}

_TruthState _ruleOverlaps({
  required Rule a,
  required Rule b,
  required List<SchemaEntry> schema,
}) {
  // Avoid noisy "overlap" findings when rules only intersect through
  // independent wildcard dimensions (no shared constrained field).
  if (!_hasSharedConstrainedField(a: a, b: b, schema: schema)) {
    return _TruthState.unknown;
  }
  var hasUnknown = false;
  for (final entry in schema) {
    final aSpec = _parseConditionSpec(a.inputs[entry.key], entry.type);
    final bSpec = _parseConditionSpec(b.inputs[entry.key], entry.type);
    final state = _fieldOverlaps(aSpec, bSpec, entry.type);
    if (state == _TruthState.no) {
      return _TruthState.no;
    }
    if (state == _TruthState.unknown) {
      hasUnknown = true;
    }
  }
  return hasUnknown ? _TruthState.unknown : _TruthState.yes;
}

bool _hasSharedConstrainedField({
  required Rule a,
  required Rule b,
  required List<SchemaEntry> schema,
}) {
  for (final entry in schema) {
    final aSpec = _parseConditionSpec(a.inputs[entry.key], entry.type);
    final bSpec = _parseConditionSpec(b.inputs[entry.key], entry.type);
    final aConstrained = aSpec.kind != _ConditionKind.wildcard;
    final bConstrained = bSpec.kind != _ConditionKind.wildcard;
    if (aConstrained && bConstrained) {
      return true;
    }
  }
  return false;
}

_ConditionSpec _parseConditionSpec(dynamic rawValue, DataType type) {
  final raw = (rawValue ?? '').toString().trim();
  if (raw.isEmpty) {
    return _ConditionSpec(kind: _ConditionKind.wildcard, raw: raw);
  }

  final cpMatch = RegExp(r'^CP\s+(.+)$', caseSensitive: false).firstMatch(raw);
  if (cpMatch != null) {
    var pattern = cpMatch.group(1)!.trim();
    pattern = _stripWrappingQuotes(pattern);
    return _ConditionSpec(
      kind: _ConditionKind.pattern,
      raw: raw,
      pattern: pattern,
    );
  }

  final rangeMatch = RegExp(
    r'^([-+]?(?:\d+(?:\.\d+)?|\.\d+))\.\.([-+]?(?:\d+(?:\.\d+)?|\.\d+))$',
  ).firstMatch(raw);
  if (rangeMatch != null) {
    final min = double.tryParse(rangeMatch.group(1)!);
    final max = double.tryParse(rangeMatch.group(2)!);
    if (min != null && max != null) {
      return _ConditionSpec(
        kind: _ConditionKind.range,
        raw: raw,
        min: min,
        max: max,
      );
    }
  }

  final cmpMatch = RegExp(
    r'^(>=|<=|>|<)\s*([-+]?(?:\d+(?:\.\d+)?|\.\d+))$',
  ).firstMatch(raw);
  if (cmpMatch != null) {
    final value = double.tryParse(cmpMatch.group(2)!);
    if (value != null) {
      return _ConditionSpec(
        kind: _ConditionKind.comparison,
        raw: raw,
        comparisonOp: cmpMatch.group(1),
        numberValue: value,
      );
    }
  }

  final inMatch =
      RegExp(r'^IN\s*\((.*)\)$', caseSensitive: false).firstMatch(raw);
  if (inMatch != null) {
    final inner = inMatch.group(1) ?? '';
    final tokens = inner
        .split(',')
        .map((t) => _stripWrappingQuotes(t.trim()))
        .where((t) => t.isNotEmpty)
        .toList();
    if (type == DataType.number || type == DataType.decimal) {
      final numbers = <double>{};
      for (final token in tokens) {
        final parsed = double.tryParse(token);
        if (parsed != null) {
          numbers.add(parsed);
        }
      }
      return _ConditionSpec(
        kind: _ConditionKind.inSet,
        raw: raw,
        numberSet: numbers,
      );
    }
    return _ConditionSpec(
      kind: _ConditionKind.inSet,
      raw: raw,
      stringSet: tokens.toSet(),
    );
  }

  if (type == DataType.number || type == DataType.decimal) {
    final number = double.tryParse(raw);
    if (number != null) {
      return _ConditionSpec(
        kind: _ConditionKind.exactNumber,
        raw: raw,
        numberValue: number,
      );
    }
  }

  return _ConditionSpec(
    kind: _ConditionKind.exactString,
    raw: raw,
    stringValue: _stripWrappingQuotes(raw),
  );
}

String _stripWrappingQuotes(String value) {
  final text = value.trim();
  if (text.length >= 2) {
    final starts = text.startsWith("'");
    final ends = text.endsWith("'");
    final startsD = text.startsWith('"');
    final endsD = text.endsWith('"');
    if ((starts && ends) || (startsD && endsD)) {
      return text.substring(1, text.length - 1);
    }
  }
  return text;
}

_TruthState _fieldCovers(
  _ConditionSpec earlier,
  _ConditionSpec later,
  DataType type,
) {
  if (earlier.kind == _ConditionKind.wildcard) {
    return _TruthState.yes;
  }
  if (later.kind == _ConditionKind.wildcard) {
    return _TruthState.no;
  }

  if (type == DataType.number || type == DataType.decimal) {
    return _numericCovers(earlier, later);
  }
  return _stringCovers(earlier, later);
}

_TruthState _fieldOverlaps(
  _ConditionSpec a,
  _ConditionSpec b,
  DataType type,
) {
  if (a.kind == _ConditionKind.wildcard || b.kind == _ConditionKind.wildcard) {
    return _TruthState.yes;
  }
  if (type == DataType.number || type == DataType.decimal) {
    return _numericOverlaps(a, b);
  }
  return _stringOverlaps(a, b);
}

_TruthState _stringCovers(_ConditionSpec a, _ConditionSpec b) {
  if (a.kind == _ConditionKind.exactString &&
      b.kind == _ConditionKind.exactString) {
    return (a.stringValue == b.stringValue) ? _TruthState.yes : _TruthState.no;
  }
  if (a.kind == _ConditionKind.inSet && b.kind == _ConditionKind.exactString) {
    return (a.stringSet?.contains(b.stringValue) ?? false)
        ? _TruthState.yes
        : _TruthState.no;
  }
  if (a.kind == _ConditionKind.inSet && b.kind == _ConditionKind.inSet) {
    final aSet = a.stringSet ?? const <String>{};
    final bSet = b.stringSet ?? const <String>{};
    return aSet.containsAll(bSet) ? _TruthState.yes : _TruthState.no;
  }
  if (a.kind == _ConditionKind.pattern &&
      b.kind == _ConditionKind.exactString) {
    return _cpMatches(a.pattern ?? '', b.stringValue ?? '')
        ? _TruthState.yes
        : _TruthState.no;
  }
  if (a.kind == _ConditionKind.pattern && b.kind == _ConditionKind.inSet) {
    final values = b.stringSet ?? const <String>{};
    if (values.isEmpty) return _TruthState.no;
    final allMatch = values.every((v) => _cpMatches(a.pattern ?? '', v));
    return allMatch ? _TruthState.yes : _TruthState.no;
  }
  if (a.kind == _ConditionKind.pattern && b.kind == _ConditionKind.pattern) {
    final pa = a.pattern ?? '';
    final pb = b.pattern ?? '';
    if (pa == pb || pa == '*') {
      return _TruthState.yes;
    }
    return _TruthState.unknown;
  }
  return _TruthState.unknown;
}

_TruthState _stringOverlaps(_ConditionSpec a, _ConditionSpec b) {
  if (a.kind == _ConditionKind.exactString &&
      b.kind == _ConditionKind.exactString) {
    return (a.stringValue == b.stringValue) ? _TruthState.yes : _TruthState.no;
  }
  if (a.kind == _ConditionKind.exactString && b.kind == _ConditionKind.inSet) {
    return (b.stringSet?.contains(a.stringValue) ?? false)
        ? _TruthState.yes
        : _TruthState.no;
  }
  if (a.kind == _ConditionKind.inSet && b.kind == _ConditionKind.exactString) {
    return _stringOverlaps(b, a);
  }
  if (a.kind == _ConditionKind.inSet && b.kind == _ConditionKind.inSet) {
    final aSet = a.stringSet ?? const <String>{};
    final bSet = b.stringSet ?? const <String>{};
    return aSet.intersection(bSet).isNotEmpty
        ? _TruthState.yes
        : _TruthState.no;
  }
  if (a.kind == _ConditionKind.pattern &&
      b.kind == _ConditionKind.exactString) {
    return _cpMatches(a.pattern ?? '', b.stringValue ?? '')
        ? _TruthState.yes
        : _TruthState.no;
  }
  if (b.kind == _ConditionKind.pattern &&
      a.kind == _ConditionKind.exactString) {
    return _stringOverlaps(b, a);
  }
  if (a.kind == _ConditionKind.pattern && b.kind == _ConditionKind.inSet) {
    final values = b.stringSet ?? const <String>{};
    if (values.isEmpty) return _TruthState.no;
    final anyMatch = values.any((v) => _cpMatches(a.pattern ?? '', v));
    return anyMatch ? _TruthState.yes : _TruthState.no;
  }
  if (b.kind == _ConditionKind.pattern && a.kind == _ConditionKind.inSet) {
    return _stringOverlaps(b, a);
  }
  if (a.kind == _ConditionKind.pattern && b.kind == _ConditionKind.pattern) {
    final pa = a.pattern ?? '';
    final pb = b.pattern ?? '';
    if (pa == pb || pa == '*' || pb == '*') {
      return _TruthState.yes;
    }
    return _TruthState.unknown;
  }
  return _TruthState.unknown;
}

_TruthState _numericCovers(_ConditionSpec a, _ConditionSpec b) {
  final aInterval = _asInterval(a);
  final bInterval = _asInterval(b);
  final aSet = _asNumberSet(a);
  final bSet = _asNumberSet(b);

  if (aInterval != null && bInterval != null) {
    return _intervalCovers(aInterval, bInterval)
        ? _TruthState.yes
        : _TruthState.no;
  }
  if (aInterval != null && bSet != null) {
    final allIn = bSet.every((v) => _intervalContains(aInterval, v));
    return allIn ? _TruthState.yes : _TruthState.no;
  }
  if (aSet != null && bSet != null) {
    return aSet.containsAll(bSet) ? _TruthState.yes : _TruthState.no;
  }
  if (aSet != null && bInterval != null) {
    return _TruthState.no;
  }
  return _TruthState.unknown;
}

_TruthState _numericOverlaps(_ConditionSpec a, _ConditionSpec b) {
  final aInterval = _asInterval(a);
  final bInterval = _asInterval(b);
  final aSet = _asNumberSet(a);
  final bSet = _asNumberSet(b);

  if (aInterval != null && bInterval != null) {
    return _intervalOverlaps(aInterval, bInterval)
        ? _TruthState.yes
        : _TruthState.no;
  }
  if (aInterval != null && bSet != null) {
    final anyIn = bSet.any((v) => _intervalContains(aInterval, v));
    return anyIn ? _TruthState.yes : _TruthState.no;
  }
  if (bInterval != null && aSet != null) {
    return _numericOverlaps(b, a);
  }
  if (aSet != null && bSet != null) {
    return aSet.intersection(bSet).isNotEmpty
        ? _TruthState.yes
        : _TruthState.no;
  }
  return _TruthState.unknown;
}

_NumericInterval? _asInterval(_ConditionSpec spec) {
  if (spec.kind == _ConditionKind.exactNumber && spec.numberValue != null) {
    final value = spec.numberValue!;
    return _NumericInterval(
      min: value,
      max: value,
      minInclusive: true,
      maxInclusive: true,
    );
  }
  if (spec.kind == _ConditionKind.range &&
      spec.min != null &&
      spec.max != null) {
    return _NumericInterval(
      min: spec.min!,
      max: spec.max!,
      minInclusive: true,
      maxInclusive: true,
    );
  }
  if (spec.kind == _ConditionKind.comparison &&
      spec.comparisonOp != null &&
      spec.numberValue != null) {
    final value = spec.numberValue!;
    switch (spec.comparisonOp) {
      case '>':
        return _NumericInterval(
          min: value,
          max: double.infinity,
          minInclusive: false,
          maxInclusive: false,
        );
      case '>=':
        return _NumericInterval(
          min: value,
          max: double.infinity,
          minInclusive: true,
          maxInclusive: false,
        );
      case '<':
        return _NumericInterval(
          min: double.negativeInfinity,
          max: value,
          minInclusive: false,
          maxInclusive: false,
        );
      case '<=':
        return _NumericInterval(
          min: double.negativeInfinity,
          max: value,
          minInclusive: false,
          maxInclusive: true,
        );
    }
  }
  return null;
}

Set<double>? _asNumberSet(_ConditionSpec spec) {
  if (spec.kind == _ConditionKind.exactNumber && spec.numberValue != null) {
    return {spec.numberValue!};
  }
  if (spec.kind == _ConditionKind.inSet && spec.numberSet != null) {
    return spec.numberSet!;
  }
  return null;
}

bool _intervalContains(_NumericInterval interval, double value) {
  final aboveMin =
      interval.minInclusive ? value >= interval.min : value > interval.min;
  final belowMax =
      interval.maxInclusive ? value <= interval.max : value < interval.max;
  return aboveMin && belowMax;
}

bool _intervalCovers(_NumericInterval a, _NumericInterval b) {
  final minCovered =
      a.min < b.min || (a.min == b.min && (a.minInclusive || !b.minInclusive));
  final maxCovered =
      a.max > b.max || (a.max == b.max && (a.maxInclusive || !b.maxInclusive));
  return minCovered && maxCovered;
}

bool _intervalOverlaps(_NumericInterval a, _NumericInterval b) {
  if (a.max < b.min || b.max < a.min) return false;
  if (a.max == b.min) return a.maxInclusive && b.minInclusive;
  if (b.max == a.min) return b.maxInclusive && a.minInclusive;
  return true;
}

bool _cpMatches(String pattern, String value) {
  final escaped =
      RegExp.escape(pattern).replaceAll(r'\*', '.*').replaceAll(r'\+', '.');
  final regex = RegExp('^$escaped\$');
  return regex.hasMatch(value);
}

_DiffSummary _buildDiffSummary(RuleTable persisted, RuleTable draft) {
  final cellDiffs = <String, Map<String, _CellDiff>>{};
  final items = <_DiffItem>[];
  final removed = <_RemovedRow>[];

  final persistedById = {for (final rule in persisted.rules) rule.id: rule};
  final draftById = {for (final rule in draft.rules) rule.id: rule};

  for (final entry in persisted.rules) {
    if (!draftById.containsKey(entry.id)) {
      removed.add(
        _RemovedRow(ruleId: entry.id, rowNumber: entry.priority + 1),
      );
    }
  }

  int addedRows = 0;

  String normalize(dynamic value) => value == null ? '' : value.toString();

  for (var i = 0; i < draft.rules.length; i++) {
    final rule = draft.rules[i];
    final beforeRule = persistedById[rule.id];
    final isNewRow = beforeRule == null;
    if (isNewRow) {
      addedRows += 1;
    }

    Map<String, _CellDiff> rowDiffs = {};

    for (final entry in draft.inputSchema) {
      final before = normalize(beforeRule?.inputs[entry.key]);
      final after = normalize(rule.inputs[entry.key]);
      final hasChange =
          isNewRow ? after.isNotEmpty : before.trim() != after.trim();
      if (!hasChange) continue;
      rowDiffs[entry.key] = _CellDiff(
        before: before,
        after: after,
        isNewRow: isNewRow,
      );
      items.add(
        _DiffItem(
          ruleId: rule.id,
          rowNumber: i + 1,
          field: entry.key,
          before: before,
          after: after,
          isOutput: false,
          isNewRow: isNewRow,
        ),
      );
    }

    for (final entry in draft.outputSchema) {
      final before = normalize(beforeRule?.outputs[entry.key]);
      final after = normalize(rule.outputs[entry.key]);
      final hasChange =
          isNewRow ? after.isNotEmpty : before.trim() != after.trim();
      if (!hasChange) continue;
      rowDiffs[entry.key] = _CellDiff(
        before: before,
        after: after,
        isNewRow: isNewRow,
      );
      items.add(
        _DiffItem(
          ruleId: rule.id,
          rowNumber: i + 1,
          field: entry.key,
          before: before,
          after: after,
          isOutput: true,
          isNewRow: isNewRow,
        ),
      );
    }

    if (rowDiffs.isNotEmpty) {
      cellDiffs[rule.id] = rowDiffs;
    }
  }

  return _DiffSummary(
    cellDiffs: cellDiffs,
    items: items,
    removedRows: removed,
    addedRows: addedRows,
  );
}

Widget _buildCellRenderer(
  PlutoColumnRendererContext rendererContext,
  _DiffSummary? summary,
  Map<String, int> flashTokens,
  Map<String, String> invalidCellMessages, {
  required bool isOutput,
}) {
  final rowKey = rendererContext.row.key as ValueKey<String>?;
  final ruleId = rowKey?.value ?? '';
  final field = rendererContext.column.field;
  final diff = summary?.cellDiffs[ruleId]?[field];
  final flashKey = '$ruleId::$field';
  final isFlashing = flashTokens.containsKey(flashKey);
  final invalidMessage = invalidCellMessages[flashKey];
  final isInvalid = invalidMessage != null;
  final rawValue = rendererContext.cell.value;
  final display = rawValue == null ? '' : rawValue.toString();

  final baseStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 10,
    color: isInvalid ? AppTheme.statusInvalid : const Color(0xFF6FB8FF),
    fontStyle: diff == null && !isInvalid ? FontStyle.normal : FontStyle.italic,
  );

  if (diff == null && !isInvalid) {
    return Text(
      display,
      style: baseStyle,
      overflow: TextOverflow.ellipsis,
    );
  }

  final bgColor =
      isInvalid ? AppTheme.statusInvalidBg : AppTheme.statusChangedBg;
  final borderColor =
      isInvalid ? AppTheme.statusInvalid : AppTheme.statusChanged;
  final flashColor =
      isInvalid ? AppTheme.statusInvalid : AppTheme.statusChanged;

  final tooltipMessage = isInvalid
      ? invalidMessage
      : (diff == null
          ? null
          : (diff.isNewRow
              ? 'New value: ${diff.after}'
              : 'Saved: ${diff.before} -> Draft: ${diff.after}'));

  final content = RichText(
    overflow: TextOverflow.ellipsis,
    text: TextSpan(
      style: baseStyle,
      children: [
        if (!isInvalid &&
            diff != null &&
            diff.before.isNotEmpty &&
            !diff.isNewRow)
          TextSpan(
            text: '${diff.before} ',
            style: baseStyle.copyWith(
              color: const Color(0xFF9AA7C4),
              decoration: TextDecoration.lineThrough,
            ),
          ),
        TextSpan(
          text: diff?.after ?? display,
          style: baseStyle.copyWith(
            color: isInvalid ? AppTheme.statusInvalid : AppTheme.statusChanged,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );

  return AnimatedContainer(
    duration: const Duration(milliseconds: 250),
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    decoration: BoxDecoration(
      color: isFlashing ? flashColor.withOpacity(0.28) : bgColor,
      borderRadius: BorderRadius.circular(2),
      border: Border.all(
        color: isFlashing ? flashColor.withOpacity(0.95) : borderColor,
        width: 0.6,
      ),
      boxShadow: isFlashing
          ? [
              BoxShadow(
                color: flashColor.withOpacity(0.35),
                blurRadius: 8,
                spreadRadius: 0.5,
              ),
            ]
          : const [],
    ),
    child: tooltipMessage == null || tooltipMessage.isEmpty
        ? content
        : Tooltip(
            message: tooltipMessage,
            waitDuration: const Duration(milliseconds: 200),
            child: content,
          ),
  );
}

class _ChangeSummaryPanel extends StatelessWidget {
  final _DiffSummary summary;
  final void Function(String ruleId, String field) onFocusCell;
  final bool isStale;
  final VoidCallback onRefresh;
  final VoidCallback onClear;

  const _ChangeSummaryPanel({
    required this.summary,
    required this.onFocusCell,
    required this.isStale,
    required this.onRefresh,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final totalChanged = summary.items.length;
    final removedCount = summary.removedRows.length;
    final addedCount = summary.addedRows;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: const Color(0xFF121B38),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: AppTheme.border),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        collapsedBackgroundColor: const Color(0xFF121B38),
        backgroundColor: const Color(0xFF121B38),
        title: Text(
          'Changes detected: $totalChanged cells, $addedCount added rows, $removedCount removed rows',
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          isStale
              ? 'Snapshot is stale. Refresh to re-detect.'
              : 'Snapshot ready. Click a row to focus.',
          style: const TextStyle(fontSize: 9, color: AppTheme.textMuted),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                OutlinedButton(
                  onPressed: onRefresh,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: AppTheme.border),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                  child: const Text('Refresh'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: onClear,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textMuted,
                    side: const BorderSide(color: AppTheme.border),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          if (summary.items.isEmpty && summary.removedRows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'No changes detected.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
              ),
            )
          else
            SizedBox(
              height: 180,
              child: ListView(
                children: [
                  for (final removed in summary.removedRows)
                    ListTile(
                      dense: true,
                      title: Text(
                        'Row ${removed.rowNumber} removed',
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppTheme.statusInvalid,
                        ),
                      ),
                      subtitle: Text(
                        removed.ruleId,
                        style: const TextStyle(
                          fontSize: 9,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                  for (final item in summary.items)
                    ListTile(
                      dense: true,
                      title: Text(
                        'Row ${item.rowNumber} - ${item.field} ${item.isOutput ? '(OUT)' : '(IN)'}',
                        style: const TextStyle(fontSize: 10),
                      ),
                      subtitle: Text(
                        item.isNewRow
                            ? 'New value: ${item.after}'
                            : 'Saved: ${item.before} -> Draft: ${item.after}',
                        style: const TextStyle(
                          fontSize: 9,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      onTap: () => onFocusCell(item.ruleId, item.field),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ConflictAnalyzerPanel extends StatelessWidget {
  final _ConflictAnalysisResult? result;
  final bool isStale;
  final VoidCallback onAnalyze;
  final VoidCallback onRefresh;
  final VoidCallback onClear;
  final void Function(_ConflictFinding finding) onApplyFix;

  const _ConflictAnalyzerPanel({
    required this.result,
    required this.isStale,
    required this.onAnalyze,
    required this.onRefresh,
    required this.onClear,
    required this.onApplyFix,
  });

  @override
  Widget build(BuildContext context) {
    if (result == null) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF121B38),
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Analyze overlaps, shadowed rules, and unreachable rules.',
                style: TextStyle(fontSize: 10, color: AppTheme.textMuted),
              ),
            ),
            OutlinedButton.icon(
              onPressed: onAnalyze,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: AppTheme.border),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.rule, size: 14),
              label: const Text('Analyze Conflicts'),
            ),
          ],
        ),
      );
    }

    final summary = result!;
    final findingCount = summary.findings.length;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: const Color(0xFF121B38),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: AppTheme.border),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        collapsedBackgroundColor: const Color(0xFF121B38),
        backgroundColor: const Color(0xFF121B38),
        title: Text(
          findingCount == 0
              ? 'No conflicts detected'
              : 'Conflicts: ${summary.overlapCount} overlap, ${summary.shadowedCount} shadowed, ${summary.unreachableCount} unreachable',
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          isStale
              ? 'Snapshot is stale. Refresh after edits.'
              : findingCount == 0
                  ? 'Snapshot ready.'
                  : 'Use one-click fixes for safe, fast cleanup.',
          style: const TextStyle(fontSize: 9, color: AppTheme.textMuted),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                OutlinedButton(
                  onPressed: onRefresh,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: AppTheme.border),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                  child: const Text('Refresh'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: onClear,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textMuted,
                    side: const BorderSide(color: AppTheme.border),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          if (summary.findings.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'No overlap, shadowing, or unreachable rule patterns were detected.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
              ),
            )
          else
            SizedBox(
              height: 200,
              child: ListView(
                children: [
                  for (final finding in summary.findings)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        _iconForConflictType(finding.type),
                        size: 16,
                        color: _colorForConflictType(finding.type),
                      ),
                      title: Text(
                        finding.message,
                        style: const TextStyle(fontSize: 10),
                      ),
                      subtitle: Text(
                        'Rows ${finding.earlierRowNumber} -> ${finding.laterRowNumber}',
                        style: const TextStyle(
                          fontSize: 9,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      trailing: finding.fix == _ConflictFix.none
                          ? null
                          : TextButton.icon(
                              onPressed: () => onApplyFix(finding),
                              style: TextButton.styleFrom(
                                foregroundColor: AppTheme.statusChanged,
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(Icons.auto_fix_high, size: 14),
                              label: Text(_labelForFix(finding.fix)),
                            ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  IconData _iconForConflictType(_ConflictType type) {
    switch (type) {
      case _ConflictType.overlap:
        return Icons.call_split;
      case _ConflictType.shadowed:
        return Icons.visibility_off;
      case _ConflictType.unreachable:
        return Icons.block;
    }
  }

  Color _colorForConflictType(_ConflictType type) {
    switch (type) {
      case _ConflictType.overlap:
        return AppTheme.statusChanged;
      case _ConflictType.shadowed:
      case _ConflictType.unreachable:
        return AppTheme.statusInvalid;
    }
  }

  String _labelForFix(_ConflictFix fix) {
    switch (fix) {
      case _ConflictFix.removeRule:
        return 'Remove later';
      case _ConflictFix.moveBefore:
        return 'Move before';
      case _ConflictFix.none:
        return 'Fix';
    }
  }
}

class _DetectChangesBar extends StatelessWidget {
  final VoidCallback onDetect;

  const _DetectChangesBar({required this.onDetect});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF121B38),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Detect changes to highlight modified cells.',
              style: TextStyle(fontSize: 10, color: AppTheme.textMuted),
            ),
          ),
          OutlinedButton.icon(
            onPressed: onDetect,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: AppTheme.border),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(2)),
              ),
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.search, size: 14),
            label: const Text('Detect Changes'),
          ),
        ],
      ),
    );
  }
}

class _OperatorChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _OperatorChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(2),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF192958),
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: AppTheme.border),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF8CC3FF),
              fontSize: 9,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }
}
