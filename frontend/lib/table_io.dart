import 'dart:convert';
import 'package:excel/excel.dart' as xlsx;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'api_client.dart';
import 'models.dart';

class RuleImportResult {
  final List<Rule> rules;
  final String objectType;
  final List<SchemaEntry> inputSchema;
  final List<SchemaEntry> outputSchema;
  final List<String> parseErrors;

  RuleImportResult({
    required this.rules,
    required this.objectType,
    required this.inputSchema,
    required this.outputSchema,
    required this.parseErrors,
  });
}

class TableIo {
  TableIo(this.apiClient);

  final RuleApiClient apiClient;

  Future<RuleImportResult?> uploadRulesFromFile({
    required RuleTable draft,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) {
      return null;
    }
    final bytes = result.files.single.bytes;
    if (bytes == null) {
      throw ApiException('Could not read selected file.');
    }
    final extension = (result.files.single.extension ?? '').toLowerCase();
    if (extension == 'json') {
      final rawText = utf8.decode(bytes, allowMalformed: true);
      final normalizedText = rawText.replaceFirst(RegExp(r'^\uFEFF'), '');
      final imported = apiClient.importTableJson(normalizedText);
      return RuleImportResult(
        rules: imported.rules,
        objectType: imported.objectType.trim(),
        inputSchema: imported.inputSchema,
        outputSchema: imported.outputSchema,
        parseErrors: const [],
      );
    }
    if (extension != 'xlsx') {
      throw ApiException('Unsupported file type. Use .xlsx or .json');
    }
    final rows = _parseXlsxRows(bytes);
    return _parseRulesRows(rows, draft, sourceLabel: 'XLSX');
  }

  Future<void> downloadRulesToXlsx(RuleTable table) async {
    if (!kIsWeb) {
      throw ApiException('Download currently supported on web build.');
    }
    final safeSlug = table.slug.trim().isEmpty ? 'rules' : table.slug.trim();
    final sanitized = safeSlug.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final fileName = '${sanitized}_rules.xlsx';
    _rulesToXlsxBytes(table, fileName: fileName);
  }

  RuleImportResult _parseRulesRows(
    List<List<String>> rows,
    RuleTable draft, {
    required String sourceLabel,
  }) {
    if (rows.isEmpty) {
      return RuleImportResult(
        rules: const [],
        objectType: draft.objectType,
        inputSchema: draft.inputSchema,
        outputSchema: draft.outputSchema,
        parseErrors: ['$sourceLabel file is empty.'],
      );
    }

    final parseErrors = <String>[];
    final inputCols = <String, int>{};
    final outputCols = <String, int>{};
    final headerColumns = _analyzeHeader(rows.first);
    final priorityCol = _findColumnIndex(headerColumns,
            key: 'priority', role: _HeaderRole.priority) ??
        _findColumnIndex(headerColumns, key: '#', role: _HeaderRole.priority) ??
        _findColumnIndex(headerColumns,
            key: 'row', role: _HeaderRole.priority) ??
        _findColumnIndex(headerColumns,
            key: 'sequence', role: _HeaderRole.priority);

    var effectiveInputSchema = draft.inputSchema;
    var effectiveOutputSchema = draft.outputSchema;
    if (effectiveInputSchema.isEmpty && effectiveOutputSchema.isEmpty) {
      final inferred = _inferSchemaFromHeader(
        headerColumns: headerColumns,
        rows: rows,
        parseErrors: parseErrors,
      );
      effectiveInputSchema = inferred.$1;
      effectiveOutputSchema = inferred.$2;
    }

    for (final entry in effectiveInputSchema) {
      final idx = _findColumnIndex(
        headerColumns,
        key: entry.key,
        role: _HeaderRole.input,
      );
      if (idx == null) {
        parseErrors.add("Missing input column '${entry.key}' in file header.");
      } else {
        inputCols[entry.key] = idx;
      }
    }
    for (final entry in effectiveOutputSchema) {
      final idx = _findColumnIndex(
        headerColumns,
        key: entry.key,
        role: _HeaderRole.output,
      );
      if (idx == null) {
        parseErrors.add("Missing output column '${entry.key}' in file header.");
      } else {
        outputCols[entry.key] = idx;
      }
    }

    if (parseErrors.isNotEmpty) {
      return RuleImportResult(
        rules: const [],
        objectType: draft.objectType,
        inputSchema: effectiveInputSchema,
        outputSchema: effectiveOutputSchema,
        parseErrors: parseErrors,
      );
    }

    final outputTypeByKey = {
      for (final e in effectiveOutputSchema) e.key: e.type
    };
    final rules = <Rule>[];

    for (var rowIdx = 1; rowIdx < rows.length; rowIdx++) {
      final row = rows[rowIdx];
      if (_isBlankRow(row)) continue;
      final rowNum = rowIdx + 1;

      int priority = rules.length;
      if (priorityCol != null && priorityCol < row.length) {
        final rawPriority = row[priorityCol].trim();
        if (rawPriority.isNotEmpty) {
          final parsed = int.tryParse(rawPriority);
          if (parsed == null) {
            parseErrors.add("Row $rowNum: priority must be an integer.");
            continue;
          }
          priority = parsed;
        }
      }

      final inputs = <String, dynamic>{};
      for (final key in inputCols.keys) {
        final col = inputCols[key]!;
        inputs[key] = col < row.length ? row[col].trim() : '';
      }

      final outputs = <String, dynamic>{};
      var rowHasError = false;
      for (final key in outputCols.keys) {
        final col = outputCols[key]!;
        final raw = col < row.length ? row[col].trim() : '';
        final parsed = _parseTypedOutput(
            raw, outputTypeByKey[key]!, rowNum, key, parseErrors);
        if (parsed == null &&
            raw.isNotEmpty &&
            outputTypeByKey[key] != DataType.string) {
          rowHasError = true;
        }
        outputs[key] =
            parsed ?? (outputTypeByKey[key] == DataType.string ? raw : 0);
      }
      if (rowHasError) continue;

      rules.add(
          Rule.create(inputs: inputs, outputs: outputs, priority: priority));
    }

    return RuleImportResult(
      rules: rules,
      objectType: draft.objectType,
      inputSchema: effectiveInputSchema,
      outputSchema: effectiveOutputSchema,
      parseErrors: parseErrors,
    );
  }

  Uint8List _rulesToXlsxBytes(
    RuleTable table, {
    String? fileName,
  }) {
    final excel = xlsx.Excel.createExcel();
    const sheetName = 'Rules';
    final defaultSheet = excel.getDefaultSheet();
    if (defaultSheet != null && defaultSheet != sheetName) {
      excel.rename(defaultSheet, sheetName);
    }
    final sheet = excel[sheetName];
    final rows = _rulesToRows(table);

    for (final row in rows) {
      sheet.appendRow(
        row
            .map<xlsx.CellValue?>(
              (value) => xlsx.TextCellValue(value),
            )
            .toList(),
      );
    }

    final bytes =
        fileName == null ? excel.save() : excel.save(fileName: fileName);
    if (bytes == null) {
      throw ApiException('Failed to generate XLSX file.');
    }
    return Uint8List.fromList(bytes);
  }

  List<List<String>> _parseXlsxRows(Uint8List bytes) {
    final excel = xlsx.Excel.decodeBytes(bytes);
    if (excel.tables.isEmpty) {
      return const [];
    }
    final firstSheetName = excel.tables.keys.first;
    final table = excel.tables[firstSheetName];
    if (table == null) {
      return const [];
    }

    return table.rows.map((row) {
      return row.map((cell) {
        final value = cell?.value;
        if (value == null) return '';
        return value.toString();
      }).toList();
    }).toList();
  }

  dynamic _parseTypedOutput(
    String raw,
    DataType type,
    int rowNum,
    String key,
    List<String> parseErrors,
  ) {
    if (raw.isEmpty) {
      return type == DataType.string ? '' : null;
    }
    switch (type) {
      case DataType.string:
        return raw;
      case DataType.number:
        final n = int.tryParse(raw);
        if (n == null) {
          parseErrors
              .add("Row $rowNum: output '$key' expects integer, got '$raw'.");
        }
        return n;
      case DataType.decimal:
        final n = num.tryParse(raw);
        if (n == null) {
          parseErrors
              .add("Row $rowNum: output '$key' expects decimal, got '$raw'.");
        }
        return n;
      case DataType.boolean:
        final normalized = raw.toLowerCase();
        if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
          return true;
        }
        if (normalized == 'false' || normalized == '0' || normalized == 'no') {
          return false;
        }
        parseErrors
            .add("Row $rowNum: output '$key' expects boolean, got '$raw'.");
        return null;
    }
  }

  List<List<String>> _rulesToRows(RuleTable table) {
    final header = <String>[
      'priority',
      ...table.inputSchema.map((e) => 'in:${e.key}'),
      ...table.outputSchema.map((e) => 'out:${e.key}'),
    ];
    final rows = <List<String>>[header];

    final sortedRules = [...table.rules]
      ..sort((a, b) => a.priority.compareTo(b.priority));
    for (final rule in sortedRules) {
      final row = <String>[rule.priority.toString()];
      for (final input in table.inputSchema) {
        row.add((rule.inputs[input.key] ?? '').toString());
      }
      for (final output in table.outputSchema) {
        final value = rule.outputs[output.key];
        row.add(value == null ? '' : value.toString());
      }
      rows.add(row);
    }
    return rows;
  }

  (_ListSchema, _ListSchema) _inferSchemaFromHeader({
    required List<_HeaderColumn> headerColumns,
    required List<List<String>> rows,
    required List<String> parseErrors,
  }) {
    final nonPriority = headerColumns
        .where((c) => c.role != _HeaderRole.priority && c.key.isNotEmpty)
        .toList();

    if (nonPriority.length < 2) {
      parseErrors.add(
        'File must contain at least two columns besides priority: one input and one output.',
      );
      return (const <SchemaEntry>[], const <SchemaEntry>[]);
    }

    final explicitInputs = <String>[];
    final explicitOutputs = <String>[];
    final neutral = <String>[];

    void addUnique(List<String> target, String key) {
      if (!target.contains(key)) {
        target.add(key);
      }
    }

    for (final col in nonPriority) {
      if (col.role == _HeaderRole.input) {
        addUnique(explicitInputs, col.key);
      } else if (col.role == _HeaderRole.output) {
        addUnique(explicitOutputs, col.key);
      } else {
        addUnique(neutral, col.key);
      }
    }

    final inputKeys = <String>[];
    final outputKeys = <String>[];

    if (explicitInputs.isEmpty && explicitOutputs.isEmpty) {
      for (var i = 0; i < neutral.length - 1; i++) {
        inputKeys.add(neutral[i]);
      }
      outputKeys.add(neutral.last);
    } else {
      inputKeys.addAll(explicitInputs);
      outputKeys.addAll(explicitOutputs);
      if (neutral.isNotEmpty) {
        if (inputKeys.isEmpty && outputKeys.isNotEmpty) {
          inputKeys.addAll(neutral);
        } else if (outputKeys.isEmpty && inputKeys.isNotEmpty) {
          outputKeys.addAll(neutral);
        } else {
          inputKeys.addAll(neutral);
        }
      }
    }

    if (inputKeys.isEmpty) {
      parseErrors.add(
        'Could not infer input schema from file header. Prefix input columns with "in:" if needed.',
      );
    }
    if (outputKeys.isEmpty) {
      parseErrors.add(
        'Could not infer output schema from file header. Prefix output columns with "out:" if needed.',
      );
    }
    if (parseErrors.isNotEmpty) {
      return (const <SchemaEntry>[], const <SchemaEntry>[]);
    }

    final inputs = inputKeys
        .map((key) => SchemaEntry.create(key, DataType.string))
        .toList();
    final outputs = outputKeys.map((key) {
      final idx =
          _findColumnIndex(headerColumns, key: key, role: _HeaderRole.output) ??
              _findColumnIndex(
                headerColumns,
                key: key,
                role: _HeaderRole.neutral,
              );
      final type = idx == null ? DataType.string : _inferDataType(rows, idx);
      return SchemaEntry.create(key, type);
    }).toList();

    return (inputs, outputs);
  }

  DataType _inferDataType(List<List<String>> rows, int columnIndex) {
    var sawValue = false;
    var allBool = true;
    var allInt = true;
    var allNum = true;

    for (var rowIdx = 1; rowIdx < rows.length; rowIdx++) {
      final row = rows[rowIdx];
      if (columnIndex >= row.length) continue;
      final raw = row[columnIndex].trim();
      if (raw.isEmpty) continue;
      sawValue = true;

      final normalized = raw.toLowerCase();
      final isBool = normalized == 'true' ||
          normalized == 'false' ||
          normalized == '1' ||
          normalized == '0' ||
          normalized == 'yes' ||
          normalized == 'no';
      if (!isBool) allBool = false;
      if (int.tryParse(raw) == null) allInt = false;
      if (num.tryParse(raw) == null) allNum = false;
    }

    if (!sawValue) return DataType.string;
    if (allBool) return DataType.boolean;
    if (allInt) return DataType.number;
    if (allNum) return DataType.decimal;
    return DataType.string;
  }

  List<_HeaderColumn> _analyzeHeader(List<String> rawHeader) {
    final columns = <_HeaderColumn>[];
    for (var i = 0; i < rawHeader.length; i++) {
      final raw = rawHeader[i].trim();
      final role = _detectRole(raw);
      columns.add(
        _HeaderColumn(
          index: i,
          raw: raw,
          key: _normalizeHeaderKey(raw),
          role: role,
        ),
      );
    }
    return columns;
  }

  _HeaderRole _detectRole(String raw) {
    final text = raw.trim().toLowerCase();
    if (text == 'priority' ||
        text == '#' ||
        text == 'row' ||
        text == 'sequence') {
      return _HeaderRole.priority;
    }
    if (text.startsWith('in:') ||
        text.startsWith('input:') ||
        text.endsWith('(in)')) {
      return _HeaderRole.input;
    }
    if (text.startsWith('out:') ||
        text.startsWith('output:') ||
        text.endsWith('(out)')) {
      return _HeaderRole.output;
    }
    return _HeaderRole.neutral;
  }

  String _normalizeHeaderKey(String raw) {
    var key = raw.trim();
    final lower = key.toLowerCase();
    if (lower.startsWith('in:')) {
      key = key.substring(3);
    } else if (lower.startsWith('input:')) {
      key = key.substring(6);
    } else if (lower.startsWith('out:')) {
      key = key.substring(4);
    } else if (lower.startsWith('output:')) {
      key = key.substring(7);
    }
    key = key.trim();

    final outSuffix = RegExp(r'\s*\((out)\)\s*$', caseSensitive: false);
    final inSuffix = RegExp(r'\s*\((in)\)\s*$', caseSensitive: false);
    key = key.replaceAll(outSuffix, '').replaceAll(inSuffix, '').trim();
    return key;
  }

  int? _findColumnIndex(
    List<_HeaderColumn> columns, {
    required String key,
    required _HeaderRole role,
  }) {
    final normalized = key.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }

    int? matchByRole(_HeaderRole probeRole) {
      for (final col in columns) {
        if (col.role != probeRole) continue;
        if (col.key.toLowerCase() == normalized ||
            col.raw.toLowerCase() == normalized) {
          return col.index;
        }
      }
      return null;
    }

    if (role == _HeaderRole.input || role == _HeaderRole.output) {
      final exactRole = matchByRole(role);
      if (exactRole != null) return exactRole;
      final neutral = matchByRole(_HeaderRole.neutral);
      if (neutral != null) return neutral;
    }

    for (final col in columns) {
      if (col.key.toLowerCase() == normalized ||
          col.raw.toLowerCase() == normalized) {
        return col.index;
      }
    }
    return null;
  }

  bool _isBlankRow(List<String> row) {
    for (final cell in row) {
      if (cell.trim().isNotEmpty) return false;
    }
    return true;
  }
}

typedef _ListSchema = List<SchemaEntry>;

enum _HeaderRole { priority, input, output, neutral }

class _HeaderColumn {
  final int index;
  final String raw;
  final String key;
  final _HeaderRole role;

  _HeaderColumn({
    required this.index,
    required this.raw,
    required this.key,
    required this.role,
  });
}
