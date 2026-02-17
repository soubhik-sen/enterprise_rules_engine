import 'package:uuid/uuid.dart';

enum DataType { string, number, decimal, boolean }

const String pendingInputKeyPrefix = '__pending_input__';
const List<String> supportedObjectTypes = <String>[
  'PURCHASE_ORDER',
  'SHIPMENT',
];

class SchemaEntry {
  final String id;
  final String key;
  final DataType type;
  final String? label;

  SchemaEntry({
    required this.id,
    required this.key,
    required this.type,
    this.label,
  });

  factory SchemaEntry.create(String key, DataType type, {String? label}) {
    return SchemaEntry(
      id: const Uuid().v4(),
      key: key,
      type: type,
      label: label,
    );
  }

  SchemaEntry copyWith({String? key, DataType? type, String? label}) {
    return SchemaEntry(
      id: id,
      key: key ?? this.key,
      type: type ?? this.type,
      label: label ?? this.label,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'key': key,
        'type': type.name,
        'label': label,
      };
}

class Rule {
  final String id;
  final String? backendId;
  final Map<String, dynamic> inputs;
  final Map<String, dynamic> outputs;
  final int priority;

  Rule({
    required this.id,
    this.backendId,
    required this.inputs,
    required this.outputs,
    required this.priority,
  });

  factory Rule.create({
    required Map<String, dynamic> inputs,
    required Map<String, dynamic> outputs,
    required int priority,
  }) {
    return Rule(
      id: const Uuid().v4(),
      backendId: null,
      inputs: inputs,
      outputs: outputs,
      priority: priority,
    );
  }

  Rule copyWith({
    String? backendId,
    Map<String, dynamic>? inputs,
    Map<String, dynamic>? outputs,
    int? priority,
  }) {
    return Rule(
      id: id,
      backendId: backendId ?? this.backendId,
      inputs: inputs ?? this.inputs,
      outputs: outputs ?? this.outputs,
      priority: priority ?? this.priority,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'backend_id': backendId,
        'inputs': inputs,
        'outputs': outputs,
        'priority': priority,
      };
}

class RuleTable {
  final String id;
  final String? backendId;
  final String name;
  final String slug;
  final String objectType;
  final String description;
  final List<SchemaEntry> inputSchema;
  final List<SchemaEntry> outputSchema;
  final List<Rule> rules;
  final String hitPolicy;

  RuleTable({
    required this.id,
    this.backendId,
    required this.name,
    required this.slug,
    this.objectType = '',
    this.description = '',
    required this.inputSchema,
    required this.outputSchema,
    required this.rules,
    this.hitPolicy = 'FIRST_HIT',
  });

  factory RuleTable.empty() {
    final suffix = const Uuid().v4().replaceAll('-', '').substring(0, 8);
    return RuleTable(
      id: const Uuid().v4(),
      backendId: null,
      name: 'New Rule Table',
      slug: 'new-rule-table-$suffix',
      objectType: '',
      description: '',
      inputSchema: [],
      outputSchema: [],
      rules: [],
    );
  }

  RuleTable copyWith({
    String? backendId,
    String? name,
    String? slug,
    String? objectType,
    String? description,
    List<SchemaEntry>? inputSchema,
    List<SchemaEntry>? outputSchema,
    List<Rule>? rules,
    String? hitPolicy,
  }) {
    return RuleTable(
      id: id,
      backendId: backendId ?? this.backendId,
      name: name ?? this.name,
      slug: slug ?? this.slug,
      objectType: objectType ?? this.objectType,
      description: description ?? this.description,
      inputSchema: inputSchema ?? this.inputSchema,
      outputSchema: outputSchema ?? this.outputSchema,
      rules: rules ?? this.rules,
      hitPolicy: hitPolicy ?? this.hitPolicy,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'backend_id': backendId,
        'name': name,
        'slug': slug,
        'object_type': objectType,
        'description': description,
        'input_schema': inputSchema.map((e) => e.toJson()).toList(),
        'output_schema': outputSchema.map((e) => e.toJson()).toList(),
        'rules': rules.map((e) => e.toJson()).toList(),
        'hit_policy': hitPolicy,
      };
}
