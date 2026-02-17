import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);

  @override
  String toString() => message;
}

class EvalResponse {
  final Map<String, dynamic> result;
  final String? ruleId;
  final List<String> matchedRuleIds;
  final String? error;
  final List<Map<String, dynamic>> trace;

  EvalResponse({
    required this.result,
    required this.ruleId,
    required this.matchedRuleIds,
    required this.error,
    required this.trace,
  });
}

class TableSummary {
  final String id;
  final String slug;
  final String description;

  TableSummary({
    required this.id,
    required this.slug,
    required this.description,
  });
}

class RuleConsistencyIssue {
  final int row;
  final String? localId;
  final String? field;
  final String message;

  RuleConsistencyIssue({
    required this.row,
    required this.localId,
    required this.field,
    required this.message,
  });
}

class RuleConsistencyResult {
  final int totalRules;
  final int errorCount;
  final List<RuleConsistencyIssue> errors;

  RuleConsistencyResult({
    required this.totalRules,
    required this.errorCount,
    required this.errors,
  });
}

class AttributeMetadata {
  final String key;
  final String type;
  final String label;

  AttributeMetadata({
    required this.key,
    required this.type,
    required this.label,
  });
}

class RuleApiClient {
  RuleApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8111',
  );
  String get baseUrl => _baseUrl;

  Future<RuleTable> saveTable(RuleTable draft) async {
    final tablePayload = {
      'slug': draft.slug,
      'object_type': draft.objectType,
      'description': draft.description,
      'hit_policy': draft.hitPolicy,
      'input_schema': _schemaToMap(draft.inputSchema),
      'output_schema': _schemaToMap(draft.outputSchema),
    };

    final rulesPayload = draft.rules
        .map(
          (rule) => {
            'local_id': rule.id,
            'priority': rule.priority,
            'logic': {
              'inputs': _normalizeInputs(rule.inputs),
              'outputs': _normalizeOutputs(rule.outputs, draft.outputSchema),
            }
          },
        )
        .toList();

    try {
      final response = await _request(
        () => _client.post(
          Uri.parse('$_baseUrl/tables/save'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'table_id': draft.backendId,
            'table': tablePayload,
            'rules': rulesPayload,
          }),
        ),
      );
      final payload = _decodeMap(response);
      final tableData = Map<String, dynamic>.from(
        payload['table'] as Map? ?? const {},
      );
      final backendTableId = tableData['id']?.toString();
      if (backendTableId == null || backendTableId.isEmpty) {
        throw ApiException('Invalid response from backend: missing table id');
      }
      final savedRules =
          List<dynamic>.from(payload['rules'] as List? ?? const []);
      final backendIdByLocal = <String, String>{};
      for (final item in savedRules) {
        final map = Map<String, dynamic>.from(item as Map);
        final localId = map['local_id']?.toString();
        final backendId = map['id']?.toString();
        if (localId != null &&
            localId.isNotEmpty &&
            backendId != null &&
            backendId.isNotEmpty) {
          backendIdByLocal[localId] = backendId;
        }
      }
      final updatedRules = draft.rules
          .map((rule) => rule.copyWith(backendId: backendIdByLocal[rule.id]))
          .toList();

      return draft.copyWith(
        backendId: backendTableId,
        slug: (tableData['slug'] ?? draft.slug).toString(),
        description: (tableData['description'] ?? draft.description).toString(),
        hitPolicy: (tableData['hit_policy'] ?? draft.hitPolicy).toString(),
        rules: updatedRules,
      );
    } on ApiException catch (e) {
      if (!_isAtomicSaveUnavailable(e)) {
        rethrow;
      }
      return _saveTableLegacy(
        draft: draft,
        tablePayload: tablePayload,
        rulesPayload: rulesPayload,
      );
    }
  }

  Future<RuleTable> _saveTableLegacy({
    required RuleTable draft,
    required Map<String, dynamic> tablePayload,
    required List<dynamic> rulesPayload,
  }) async {
    final existingTableId = draft.backendId?.trim();
    final hasExistingTableId =
        existingTableId != null && existingTableId.isNotEmpty;

    final tableResponse = await _request(
      () => hasExistingTableId
          ? _client.put(
              Uri.parse('$_baseUrl/tables/$existingTableId'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(tablePayload),
            )
          : _client.post(
              Uri.parse('$_baseUrl/tables'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(tablePayload),
            ),
    );
    final tableData = _decodeMap(tableResponse);
    final backendTableId = tableData['id']?.toString();
    if (backendTableId == null || backendTableId.isEmpty) {
      throw ApiException('Invalid response from backend: missing table id');
    }

    final legacyRulesPayload = rulesPayload.map((raw) {
      final item = Map<String, dynamic>.from(raw as Map);
      return {
        'priority': item['priority'],
        'logic': item['logic'],
      };
    }).toList();

    final rulesResponse = await _request(
      () => _client.put(
        Uri.parse('$_baseUrl/tables/$backendTableId/rules'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(legacyRulesPayload),
      ),
    );
    final savedRules = _decodeList(rulesResponse);
    final backendIdByLocal = _mapBackendRuleIdsByPriority(
      draft.rules,
      savedRules,
    );
    final updatedRules = draft.rules
        .map((rule) => rule.copyWith(backendId: backendIdByLocal[rule.id]))
        .toList();

    return draft.copyWith(
      backendId: backendTableId,
      slug: (tableData['slug'] ?? draft.slug).toString(),
      description: (tableData['description'] ?? draft.description).toString(),
      hitPolicy: (tableData['hit_policy'] ?? draft.hitPolicy).toString(),
      rules: updatedRules,
    );
  }

  bool _isAtomicSaveUnavailable(ApiException error) {
    final message = error.message;
    return message.contains('HTTP 404') || message.contains('HTTP 405');
  }

  Map<String, String> _mapBackendRuleIdsByPriority(
    List<Rule> localRules,
    List<dynamic> savedRules,
  ) {
    final pendingLocalByPriority = <int, List<Rule>>{};
    for (final rule in localRules) {
      pendingLocalByPriority
          .putIfAbsent(rule.priority, () => <Rule>[])
          .add(rule);
    }

    final backendIdByLocal = <String, String>{};
    for (final raw in savedRules) {
      final item = Map<String, dynamic>.from(raw as Map);
      final backendId = item['id']?.toString();
      final priorityRaw = item['priority'];
      final priority = priorityRaw is int
          ? priorityRaw
          : int.tryParse(priorityRaw?.toString() ?? '');
      if (backendId == null || backendId.isEmpty || priority == null) {
        continue;
      }

      final candidates = pendingLocalByPriority[priority];
      if (candidates == null || candidates.isEmpty) {
        continue;
      }

      final localRule = candidates.removeAt(0);
      backendIdByLocal[localRule.id] = backendId;
    }

    return backendIdByLocal;
  }

  Future<RuleTable> fetchTableBySlug(String slug) async {
    final tableResponse = await _request(
      () => _client.get(
        Uri.parse('$_baseUrl/tables/by-slug/$slug'),
      ),
    );
    final tableData = _decodeMap(tableResponse);
    final tableId = tableData['id'].toString();

    final rulesResponse = await _request(
      () => _client.get(
        Uri.parse('$_baseUrl/tables/$tableId/rules'),
      ),
    );
    final rulesData = _decodeList(rulesResponse);

    final inputSchema = _schemaFromMap(
        tableData['input_schema'] as Map<String, dynamic>? ?? {});
    final outputSchema = _schemaFromMap(
        tableData['output_schema'] as Map<String, dynamic>? ?? {});

    final rules = rulesData.map((raw) {
      final item = raw as Map<String, dynamic>;
      final logic = item['logic'] as Map<String, dynamic>? ?? {};
      return Rule(
        id: item['id'].toString(),
        backendId: item['id'].toString(),
        inputs: Map<String, dynamic>.from(logic['inputs'] as Map? ?? const {}),
        outputs:
            Map<String, dynamic>.from(logic['outputs'] as Map? ?? const {}),
        priority: item['priority'] as int? ?? 0,
      );
    }).toList();

    return RuleTable(
      id: tableId,
      backendId: tableId,
      name: slug,
      slug: slug,
      objectType: (tableData['object_type'] ?? tableData['objectType'] ?? '')
          .toString()
          .trim(),
      description: (tableData['description'] ?? '').toString(),
      inputSchema: inputSchema,
      outputSchema: outputSchema,
      rules: rules,
      hitPolicy: (tableData['hit_policy'] ?? 'FIRST_HIT').toString(),
    );
  }

  Future<List<TableSummary>> listTables({String? search}) async {
    final query = (search != null && search.trim().isNotEmpty)
        ? '?search=${Uri.encodeQueryComponent(search.trim())}'
        : '';
    final response = await _request(
      () => _client.get(
        Uri.parse('$_baseUrl/tables$query'),
      ),
    );
    final rows = _decodeList(response);
    return rows.map((row) {
      final item = Map<String, dynamic>.from(row as Map);
      return TableSummary(
        id: item['id'].toString(),
        slug: item['slug'].toString(),
        description: (item['description'] ?? '').toString(),
      );
    }).toList();
  }

  Future<void> deleteTableById(String tableId) async {
    final normalized = tableId.trim();
    if (normalized.isEmpty) {
      throw ApiException('Table id is required to delete a table.');
    }
    await _request(
      () => _client.delete(
        Uri.parse('$_baseUrl/tables/$normalized'),
      ),
    );
  }

  Future<List<AttributeMetadata>> fetchAttributeMetadata({
    required String objectType,
    String? scope,
  }) async {
    final normalized = objectType.trim();
    if (normalized.isEmpty) {
      throw ApiException('Object type is required to load attributes.');
    }
    final query = (scope != null && scope.trim().isNotEmpty)
        ? '?scope=${Uri.encodeQueryComponent(scope.trim())}'
        : '';
    final response = await _request(
      () => _client.get(
        Uri.parse(
          '$_baseUrl/proxy/metadata/attributes/'
          '${Uri.encodeComponent(normalized)}$query',
        ),
      ),
    );
    final payload = _decodeMap(response);
    final attributesRaw =
        List<dynamic>.from(payload['attributes'] as List? ?? const []);
    return attributesRaw.map((raw) {
      final item = Map<String, dynamic>.from(raw as Map);
      return AttributeMetadata(
        key: (item['key'] ?? '').toString(),
        type: (item['type'] ?? '').toString(),
        label: (item['label'] ?? '').toString(),
      );
    }).toList();
  }

  Future<EvalResponse> evaluatePersisted({
    required String slug,
    required Map<String, dynamic> context,
    bool detailed = false,
  }) async {
    final response = await _request(
      () => _client.post(
        Uri.parse('$_baseUrl/evaluate'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'table_slug': slug,
          'context': context,
          'detailed': detailed,
        }),
      ),
    );
    return _parseEvalResponse(response);
  }

  Future<EvalResponse> simulateDraft({
    required RuleTable draft,
    required Map<String, dynamic> context,
    bool detailed = false,
  }) async {
    final response = await _request(
      () => _client.post(
        Uri.parse('$_baseUrl/simulate'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'context': context,
          'detailed': detailed,
          'table_definition': {
            'slug': draft.slug,
            'hit_policy': draft.hitPolicy,
            'input_schema': _schemaToMap(draft.inputSchema),
            'output_schema': _schemaToMap(draft.outputSchema),
            'rules': draft.rules
                .map(
                  (rule) => {
                    'id': rule.id,
                    'priority': rule.priority,
                    'logic': {
                      'inputs': _normalizeInputs(rule.inputs),
                      'outputs':
                          _normalizeOutputs(rule.outputs, draft.outputSchema),
                    },
                  },
                )
                .toList(),
          },
        }),
      ),
    );
    return _parseEvalResponse(response);
  }

  Future<RuleConsistencyResult> checkRulesConsistency({
    required RuleTable draft,
    required List<Rule> rules,
  }) async {
    final response = await _request(
      () => _client.post(
        Uri.parse('$_baseUrl/rules/consistency-check'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'table': {
            'slug': draft.slug,
            'object_type': draft.objectType,
            'description': draft.description,
            'hit_policy': draft.hitPolicy,
            'input_schema': _schemaToMap(draft.inputSchema),
            'output_schema': _schemaToMap(draft.outputSchema),
          },
          'rules': rules
              .map(
                (rule) => {
                  'local_id': rule.id,
                  'priority': rule.priority,
                  'logic': {
                    'inputs': _normalizeInputs(rule.inputs),
                    'outputs':
                        _normalizeOutputs(rule.outputs, draft.outputSchema),
                  },
                },
              )
              .toList(),
        }),
      ),
    );
    final payload = _decodeMap(response);
    final errorsRaw =
        List<dynamic>.from(payload['errors'] as List? ?? const []);
    final issues = errorsRaw
        .map((raw) {
          final item = Map<String, dynamic>.from(raw as Map);
          return RuleConsistencyIssue(
            row: item['row'] as int? ?? 0,
            localId: item['local_id']?.toString(),
            field: item['field']?.toString(),
            message: (item['message'] ?? '').toString(),
          );
        })
        .where((e) => e.message.isNotEmpty)
        .toList();
    return RuleConsistencyResult(
      totalRules: payload['total_rules'] as int? ?? rules.length,
      errorCount: payload['error_count'] as int? ?? issues.length,
      errors: issues,
    );
  }

  EvalResponse _parseEvalResponse(http.Response response) {
    final payload = _decodeMap(response);
    return EvalResponse(
      result: Map<String, dynamic>.from(payload['result'] as Map? ?? const {}),
      ruleId: payload['rule_id']?.toString(),
      matchedRuleIds:
          List<String>.from(payload['matched_rule_ids'] as List? ?? const []),
      error: payload['error']?.toString(),
      trace: List<dynamic>.from(payload['trace'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(),
    );
  }

  Map<String, String> _schemaToMap(List<SchemaEntry> entries) {
    final result = <String, String>{};
    for (final entry in entries) {
      final key = entry.key.trim();
      if (key.isNotEmpty) {
        result[key] = _dataTypeToString(entry.type);
      }
    }
    return result;
  }

  List<SchemaEntry> _schemaFromMap(Map<String, dynamic> schema) {
    final entries = <SchemaEntry>[];
    schema.forEach((key, value) {
      entries.add(SchemaEntry.create(key, _stringToDataType(value.toString())));
    });
    return entries;
  }

  Map<String, dynamic> _normalizeInputs(Map<String, dynamic> inputs) {
    final normalized = <String, dynamic>{};
    inputs.forEach((key, value) {
      if (value == null) {
        normalized[key] = '';
        return;
      }
      final text = value.toString().trim();
      // Empty/whitespace condition means wildcard: accept all values.
      normalized[key] = text.isEmpty ? '' : text;
    });
    return normalized;
  }

  Map<String, dynamic> _normalizeOutputs(
    Map<String, dynamic> outputs,
    List<SchemaEntry> outputSchema,
  ) {
    final schemaByKey = {
      for (final entry in outputSchema) entry.key: entry.type
    };
    final normalized = <String, dynamic>{};
    outputs.forEach((key, value) {
      final dataType = schemaByKey[key];
      normalized[key] = _normalizeTypedOutput(value, dataType);
    });
    return normalized;
  }

  dynamic _normalizeTypedOutput(dynamic value, DataType? dataType) {
    if (dataType == null) return value;
    if (dataType == DataType.number || dataType == DataType.decimal) {
      if (value is num) return value;
      return num.tryParse(value.toString()) ?? 0;
    }
    if (dataType == DataType.boolean) {
      if (value is bool) return value;
      final raw = value.toString().toLowerCase();
      if (raw == 'true') return true;
      if (raw == 'false') return false;
      return false;
    }
    return value?.toString() ?? '';
  }

  String _dataTypeToString(DataType type) {
    switch (type) {
      case DataType.string:
        return 'string';
      case DataType.number:
        return 'number';
      case DataType.decimal:
        return 'decimal';
      case DataType.boolean:
        return 'boolean';
    }
  }

  DataType _stringToDataType(String type) {
    switch (type.toLowerCase()) {
      case 'number':
        return DataType.number;
      case 'decimal':
        return DataType.decimal;
      case 'boolean':
        return DataType.boolean;
      case 'string':
      default:
        return DataType.string;
    }
  }

  String exportTableJson(RuleTable table) {
    final payload = {
      'slug': table.slug,
      'object_type': table.objectType,
      'description': table.description,
      'hit_policy': table.hitPolicy,
      'input_schema': _schemaToMap(table.inputSchema),
      'output_schema': _schemaToMap(table.outputSchema),
      'rules': table.rules
          .map(
            (rule) => {
              'priority': rule.priority,
              'logic': {
                'inputs': _normalizeInputs(rule.inputs),
                'outputs': _normalizeOutputs(rule.outputs, table.outputSchema),
              }
            },
          )
          .toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  RuleTable importTableJson(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw ApiException('Invalid JSON format: expected object root.');
    }

    final map = Map<String, dynamic>.from(decoded);
    final slug = (map['slug'] ?? '').toString().trim();
    if (slug.isEmpty) {
      throw ApiException('Invalid JSON: table slug is required.');
    }

    final inputSchema = _schemaFromMap(
        Map<String, dynamic>.from(map['input_schema'] as Map? ?? const {}));
    final outputSchema = _schemaFromMap(
        Map<String, dynamic>.from(map['output_schema'] as Map? ?? const {}));
    final outputTypeByKey = {for (final e in outputSchema) e.key: e.type};

    final rulesRaw = List<dynamic>.from(map['rules'] as List? ?? const []);
    final rules = <Rule>[];
    for (final rawRule in rulesRaw) {
      final rule = Map<String, dynamic>.from(rawRule as Map);
      final logic =
          Map<String, dynamic>.from(rule['logic'] as Map? ?? const {});
      final inputs =
          Map<String, dynamic>.from(logic['inputs'] as Map? ?? const {});
      final outputs =
          Map<String, dynamic>.from(logic['outputs'] as Map? ?? const {});
      final normalizedOutputs = <String, dynamic>{};
      outputs.forEach((key, value) {
        normalizedOutputs[key] =
            _normalizeTypedOutput(value, outputTypeByKey[key]);
      });
      rules.add(
        Rule.create(
          inputs: inputs,
          outputs: normalizedOutputs,
          priority: (rule['priority'] as int?) ?? rules.length,
        ),
      );
    }

    final description = (map['description'] ?? '').toString();
    final objectType =
        (map['object_type'] ?? map['objectType'] ?? '').toString();
    return RuleTable.empty().copyWith(
      slug: slug,
      name: slug,
      objectType: objectType.trim(),
      description: description,
      hitPolicy: (map['hit_policy'] ?? 'FIRST_HIT').toString(),
      inputSchema: inputSchema,
      outputSchema: outputSchema,
      rules: rules,
    );
  }

  Map<String, dynamic> _decodeMap(http.Response response) {
    final body =
        response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(_errorFromResponse(body, response.statusCode));
    }
    if (body is Map) {
      return Map<String, dynamic>.from(body);
    }
    throw ApiException('Invalid response from backend (expected JSON object)');
  }

  List<dynamic> _decodeList(http.Response response) {
    final body =
        response.body.isEmpty ? <dynamic>[] : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(_errorFromResponse(body, response.statusCode));
    }
    if (body is List) {
      return List<dynamic>.from(body);
    }
    throw ApiException('Invalid response from backend (expected JSON list)');
  }

  String _errorFromResponse(dynamic body, int status) {
    if (body is Map && body['detail'] != null) {
      return '${body['detail']} (HTTP $status)';
    }
    return 'Request failed with HTTP $status';
  }

  Future<http.Response> _request(Future<http.Response> Function() call) async {
    try {
      return await call();
    } on http.ClientException catch (e) {
      throw ApiException('Network error against $_baseUrl: ${e.message}');
    } catch (_) {
      throw ApiException(
        'Cannot reach backend at $_baseUrl. Start the FastAPI server and retry.',
      );
    }
  }
}
