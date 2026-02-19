import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'api_client.dart';
import 'app_theme.dart';
import 'models.dart';
import 'providers.dart';

class SchemaWizard extends ConsumerWidget {
  const SchemaWizard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(draftTableProvider);
    final inputAttributes = ref.watch(inputAttributeOptionsProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('TABLE SETTINGS'),
          const SizedBox(height: 10),
          const _TableSettingsCard(),
          const SizedBox(height: 18),
          _SchemaBlock(
            title: 'INPUT SCHEMA',
            entries: draft.inputSchema,
            availableAttributes: inputAttributes,
            lockTypeFromAttributes: true,
            onAdd: () => _addField(
              context,
              ref,
              draft,
              isInput: true,
              availableAttributes: inputAttributes,
            ),
            onChanged: (before, after) => _changeField(context, ref, draft,
                before: before, after: after, isInput: true),
            onRemove: (entry) =>
                _removeField(context, ref, draft, entry, isInput: true),
          ),
          const SizedBox(height: 16),
          _SchemaBlock(
            title: 'OUTPUT SCHEMA',
            entries: draft.outputSchema,
            onAdd: () => _addField(context, ref, draft, isInput: false),
            onChanged: (before, after) => _changeField(context, ref, draft,
                before: before, after: after, isInput: false),
            onRemove: (entry) =>
                _removeField(context, ref, draft, entry, isInput: false),
          ),
        ],
      ),
    );
  }

  void _addField(
    BuildContext context,
    WidgetRef ref,
    RuleTable draft, {
    required bool isInput,
    List<AttributeMetadata> availableAttributes = const [],
  }) {
    final existing = (isInput ? draft.inputSchema : draft.outputSchema)
        .map((e) => e.key)
        .toList();
    SchemaEntry entry;
    if (isInput && availableAttributes.isNotEmpty) {
      final usedKeys = draft.inputSchema
          .map((e) => e.key.trim())
          .where(
            (key) => key.isNotEmpty && !key.startsWith(pendingInputKeyPrefix),
          )
          .toSet();
      final hasUnused = availableAttributes
          .map((e) => e.key.trim())
          .where((key) => key.isNotEmpty)
          .any((key) => !usedKeys.contains(key));
      if (!hasUnused) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'All attributes for this object type are already used.',
            ),
            backgroundColor: AppTheme.danger,
          ),
        );
        return;
      }
      entry = SchemaEntry.create(
        '$pendingInputKeyPrefix${DateTime.now().microsecondsSinceEpoch}',
        DataType.string,
      );
    } else if (!isInput && availableAttributes.isNotEmpty) {
      final next = availableAttributes.firstWhere(
        (attr) => !existing.contains(attr.key.trim()),
        orElse: () => availableAttributes.first,
      );
      final key = next.key.trim();
      entry = SchemaEntry.create(
        key.isEmpty ? _nextFieldName(existing, 'output') : key,
        _mapAttributeType(next.type),
        label: next.label,
      );
    } else {
      final fieldName = _nextFieldName(existing, isInput ? 'input' : 'output');
      entry = SchemaEntry.create(fieldName, DataType.string);
    }

    final updatedSchema = [
      ...(isInput ? draft.inputSchema : draft.outputSchema),
      entry,
    ];

    final updatedRules = draft.rules
        .map(
          (rule) => isInput
              ? rule.copyWith(
                  inputs: entry.key.trim().isEmpty ||
                          entry.key.startsWith(pendingInputKeyPrefix)
                      ? Map<String, dynamic>.from(rule.inputs)
                      : {...rule.inputs, entry.key: ''},
                )
              : rule.copyWith(outputs: {...rule.outputs, entry.key: ''}),
        )
        .toList();

    ref.read(draftTableProvider.notifier).state = isInput
        ? draft.copyWith(inputSchema: updatedSchema, rules: updatedRules)
        : draft.copyWith(outputSchema: updatedSchema, rules: updatedRules);
    if (isInput) {
      ref.read(bumpObjectTypeSchemaRevisionProvider)(draft.objectType);
    }
  }

  void _changeField(
    BuildContext context,
    WidgetRef ref,
    RuleTable draft, {
    required SchemaEntry before,
    required SchemaEntry after,
    required bool isInput,
  }) {
    final schema = (isInput ? draft.inputSchema : draft.outputSchema)
        .map((e) => e.id == after.id ? after : e)
        .toList();
    final trimmedNewKey = after.key.trim();
    final trimmedOldKey = before.key.trim();
    if (trimmedNewKey != trimmedOldKey &&
        trimmedNewKey.isNotEmpty &&
        !trimmedNewKey.startsWith(pendingInputKeyPrefix)) {
      final duplicateExists = schema.any(
        (e) => e.id != after.id && e.key.trim() == trimmedNewKey,
      );
      if (duplicateExists) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Duplicate attributes are not allowed in a table.'),
            backgroundColor: AppTheme.danger,
          ),
        );
        return;
      }
    }

    final oldKey = before.key;
    final newKey = after.key;
    final updatedRules = draft.rules
        .map(
          (rule) => isInput
              ? rule.copyWith(
                  inputs: _renameRuleKey(rule.inputs, oldKey, newKey))
              : rule.copyWith(
                  outputs: _renameRuleKey(rule.outputs, oldKey, newKey)),
        )
        .toList();

    ref.read(draftTableProvider.notifier).state = isInput
        ? draft.copyWith(inputSchema: schema, rules: updatedRules)
        : draft.copyWith(outputSchema: schema, rules: updatedRules);
    if (isInput) {
      ref.read(bumpObjectTypeSchemaRevisionProvider)(draft.objectType);
    }
  }

  void _removeField(
    BuildContext context,
    WidgetRef ref,
    RuleTable draft,
    SchemaEntry entry, {
    required bool isInput,
  }) {
    final currentSchema = isInput ? draft.inputSchema : draft.outputSchema;
    if (currentSchema.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isInput
                ? 'At least one input column is required.'
                : 'At least one output column is required.',
          ),
          backgroundColor: AppTheme.danger,
        ),
      );
      return;
    }

    final schema = currentSchema.where((e) => e.id != entry.id).toList();

    final updatedRules = draft.rules.map(
      (rule) {
        if (isInput) {
          final inputs = Map<String, dynamic>.from(rule.inputs);
          inputs.remove(entry.key);
          return rule.copyWith(inputs: inputs);
        }
        final outputs = Map<String, dynamic>.from(rule.outputs);
        outputs.remove(entry.key);
        return rule.copyWith(outputs: outputs);
      },
    ).toList();

    ref.read(draftTableProvider.notifier).state = isInput
        ? draft.copyWith(inputSchema: schema, rules: updatedRules)
        : draft.copyWith(outputSchema: schema, rules: updatedRules);
    if (isInput) {
      ref.read(bumpObjectTypeSchemaRevisionProvider)(draft.objectType);
    }
  }

  DataType _mapAttributeType(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'number':
        return DataType.number;
      case 'decimal':
        return DataType.decimal;
      case 'bool':
      case 'boolean':
        return DataType.boolean;
      case 'date':
      case 'datetime':
        return DataType.string;
      case 'string':
      default:
        return DataType.string;
    }
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        letterSpacing: 1.8,
        color: AppTheme.textMuted,
        fontWeight: FontWeight.w600,
        fontSize: 8,
      ),
    );
  }
}

class _TableSettingsCard extends ConsumerStatefulWidget {
  const _TableSettingsCard();

  @override
  ConsumerState<_TableSettingsCard> createState() => _TableSettingsCardState();
}

class _TableSettingsCardState extends ConsumerState<_TableSettingsCard> {
  late final TextEditingController _slugCtrl;
  late final TextEditingController _descCtrl;
  String _loadedObjectType = '';

  @override
  void initState() {
    super.initState();
    final draft = ref.read(draftTableProvider);
    _slugCtrl = TextEditingController(text: draft.slug);
    _descCtrl = TextEditingController(text: draft.description);
    _slugCtrl.addListener(_onSlugChanged);
    _descCtrl.addListener(_onDescriptionChanged);
    _loadedObjectType = draft.objectType.trim().toUpperCase();
    if (supportedObjectTypes.contains(_loadedObjectType)) {
      Future.microtask(() => _loadInputAttributes(_loadedObjectType));
    } else {
      _loadedObjectType = '';
    }
  }

  @override
  void dispose() {
    _slugCtrl.removeListener(_onSlugChanged);
    _descCtrl.removeListener(_onDescriptionChanged);
    _slugCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  void _onSlugChanged() {
    final draft = ref.read(draftTableProvider);
    final slug = _slugCtrl.text.trim();
    final name = slug.isEmpty ? 'New Rule Table' : slug;
    if (draft.slug == slug && draft.name == name) {
      return;
    }
    ref.read(draftTableProvider.notifier).state = draft.copyWith(
      slug: slug,
      name: name,
    );
  }

  void _onDescriptionChanged() {
    final draft = ref.read(draftTableProvider);
    final description = _descCtrl.text.trimLeft();
    if (draft.description == description) return;
    ref.read(draftTableProvider.notifier).state = draft.copyWith(
      description: description,
    );
  }

  Future<void> _onObjectTypeSelected(String objectType) async {
    final draft = ref.read(draftTableProvider);
    final normalized = objectType.trim().toUpperCase();
    if (draft.objectType.trim().toUpperCase() == normalized) return;
    final resetRules = draft.rules
        .map((rule) => rule.copyWith(inputs: const <String, dynamic>{}))
        .toList();
    ref.read(draftTableProvider.notifier).state = draft.copyWith(
      objectType: normalized,
      inputSchema: const [],
      rules: resetRules,
    );
    ref.read(objectTypeOriginProvider.notifier).state =
        ObjectTypeOrigin.explicit;
    ref.read(bumpObjectTypeSchemaRevisionProvider)(normalized);
    ref.read(inputAttributeOptionsProvider.notifier).state = const [];
    _loadedObjectType = normalized;
    if (normalized.isEmpty) {
      return;
    }
    await _loadInputAttributes(normalized);
  }

  Future<void> _loadInputAttributes(String objectType) async {
    try {
      await ref.read(loadInputAttributeOptionsActionProvider)(objectType);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: AppTheme.danger),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to load input attributes: $e'),
          backgroundColor: AppTheme.danger,
        ),
      );
    }
  }

  void _syncController(TextEditingController controller, String value) {
    if (controller.text == value) return;
    final base = controller.selection.baseOffset;
    final offset = base < 0 ? value.length : base.clamp(0, value.length);
    controller.value = controller.value.copyWith(
      text: value,
      selection: TextSelection.collapsed(offset: offset),
      composing: TextRange.empty,
    );
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(draftTableProvider);
    final isLoadedFromDb = ref.watch(isLoadedTableProvider);
    final currentObjectType = draft.objectType.trim().toUpperCase();
    if (currentObjectType != _loadedObjectType) {
      _loadedObjectType = currentObjectType;
      Future.microtask(() async {
        if (!mounted) return;
        ref.read(inputAttributeOptionsProvider.notifier).state = const [];
        if (supportedObjectTypes.contains(currentObjectType)) {
          await _loadInputAttributes(currentObjectType);
        } else {
          _loadedObjectType = '';
        }
      });
    }
    _syncController(_slugCtrl, draft.slug);
    _syncController(_descCtrl, draft.description);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('TABLE NAME',
            style: TextStyle(fontSize: 8, color: AppTheme.textMuted)),
        const SizedBox(height: 3),
        SizedBox(
          height: 54,
          child: TextField(
            enabled: !isLoadedFromDb,
            controller: _slugCtrl,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
              hintText: 'user_auth_v1',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 11),
            ),
            textAlignVertical: TextAlignVertical.center,
          ),
        ),
        const SizedBox(height: 1),
        const Text('OBJECT TYPE',
            style: TextStyle(fontSize: 8, color: AppTheme.textMuted)),
        const SizedBox(height: 2),
        SizedBox(
          height: 46,
          child: DropdownButtonFormField<String>(
            value: supportedObjectTypes.contains(currentObjectType)
                ? currentObjectType
                : null,
            isDense: true,
            dropdownColor: AppTheme.panelSoft,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
            icon: const Icon(Icons.keyboard_arrow_down, size: 12),
            decoration: const InputDecoration(
              hintText: 'Select object type',
              hintStyle: TextStyle(
                fontSize: 10,
                color: AppTheme.textMuted,
              ),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            ),
            items: supportedObjectTypes
                .map(
                  (value) => DropdownMenuItem(
                    value: value,
                    child: Text(value),
                  ),
                )
                .toList(),
            onChanged: isLoadedFromDb
                ? null
                : (value) {
                    if (value == null) return;
                    _onObjectTypeSelected(value);
                  },
          ),
        ),
        const SizedBox(height: 1),
        const Text('DESCRIPTION',
            style: TextStyle(fontSize: 8, color: AppTheme.textMuted)),
        const SizedBox(height: 2),
        SizedBox(
          height: 54,
          child: TextField(
            enabled: !isLoadedFromDb,
            maxLength: 240,
            controller: _descCtrl,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(
              hintText: 'Short purpose of table',
              counterText: '',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 11),
            ),
            textAlignVertical: TextAlignVertical.center,
          ),
        ),
        const SizedBox(height: 6),
        const Text('HIT POLICY',
            style: TextStyle(fontSize: 8, color: AppTheme.textMuted)),
        const SizedBox(height: 3),
        SizedBox(
          height: 24,
          child: DropdownButtonFormField<String>(
            value: draft.hitPolicy,
            icon: const Icon(Icons.keyboard_arrow_down, size: 10),
            isDense: true,
            dropdownColor: AppTheme.panelSoft,
            style: const TextStyle(
              fontSize: 7,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
            items: const [
              DropdownMenuItem(
                  value: 'FIRST_HIT',
                  child: Text('FIRST_HIT',
                      style: TextStyle(fontSize: 7, color: Colors.white))),
              DropdownMenuItem(
                  value: 'COLLECT_ALL',
                  child: Text('COLLECT_ALL',
                      style: TextStyle(fontSize: 7, color: Colors.white))),
              DropdownMenuItem(
                  value: 'UNIQUE',
                  child: Text('UNIQUE',
                      style: TextStyle(fontSize: 7, color: Colors.white))),
            ],
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            ),
            onChanged: (val) {
              if (val == null) return;
              ref.read(draftTableProvider.notifier).state =
                  draft.copyWith(hitPolicy: val);
            },
          ),
        ),
      ],
    );
  }
}

class _SchemaBlock extends StatelessWidget {
  final String title;
  final List<SchemaEntry> entries;
  final List<AttributeMetadata> availableAttributes;
  final bool lockTypeFromAttributes;
  final VoidCallback onAdd;
  final void Function(SchemaEntry before, SchemaEntry after) onChanged;
  final void Function(SchemaEntry entry) onRemove;

  const _SchemaBlock({
    required this.title,
    required this.entries,
    this.availableAttributes = const [],
    this.lockTypeFromAttributes = false,
    required this.onAdd,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final canRemove = entries.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SectionLabel(title),
            const Spacer(),
            InkWell(
              onTap: onAdd,
              borderRadius: BorderRadius.circular(2),
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A2450),
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: const Color(0xFF2A3769)),
                ),
                child: const Icon(Icons.add, color: AppTheme.accent, size: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (entries.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.panelSoft,
              borderRadius: BorderRadius.circular(2),
              border: Border.all(color: AppTheme.border),
            ),
            child: const Text(
              'No fields yet. Click + to add.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 8),
            ),
          ),
        ...entries.map((entry) {
          return _SchemaEntryRow(
            entry: entry,
            availableAttributes: availableAttributes,
            reservedKeys: entries
                .where((e) => e.id != entry.id)
                .map((e) => e.key.trim())
                .where((key) => key.isNotEmpty)
                .toSet(),
            lockTypeFromAttributes: lockTypeFromAttributes,
            onChanged: (updated) => onChanged(entry, updated),
            onRemove: () => onRemove(entry),
            canRemove: canRemove,
          );
        }),
      ],
    );
  }
}

class _SchemaEntryRow extends StatefulWidget {
  final SchemaEntry entry;
  final List<AttributeMetadata> availableAttributes;
  final Set<String> reservedKeys;
  final bool lockTypeFromAttributes;
  final ValueChanged<SchemaEntry> onChanged;
  final VoidCallback onRemove;
  final bool canRemove;

  const _SchemaEntryRow({
    required this.entry,
    this.availableAttributes = const [],
    this.reservedKeys = const {},
    this.lockTypeFromAttributes = false,
    required this.onChanged,
    required this.onRemove,
    this.canRemove = true,
  });

  @override
  State<_SchemaEntryRow> createState() => _SchemaEntryRowState();
}

class _SchemaEntryRowState extends State<_SchemaEntryRow> {
  late final TextEditingController _keyCtrl;

  @override
  void initState() {
    super.initState();
    _keyCtrl = TextEditingController(text: widget.entry.key);
    _keyCtrl.addListener(_onKeyChanged);
  }

  @override
  void didUpdateWidget(covariant _SchemaEntryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_keyCtrl.text != widget.entry.key) {
      _keyCtrl.value = TextEditingValue(
        text: widget.entry.key,
        selection: TextSelection.collapsed(offset: widget.entry.key.length),
      );
    }
  }

  @override
  void dispose() {
    _keyCtrl.removeListener(_onKeyChanged);
    _keyCtrl.dispose();
    super.dispose();
  }

  void _onKeyChanged() {
    widget.onChanged(widget.entry.copyWith(key: _keyCtrl.text));
  }

  @override
  Widget build(BuildContext context) {
    final hasAttributeDropdown = widget.availableAttributes.isNotEmpty;
    final currentKey = widget.entry.key.trim();
    final isPendingInputKey = currentKey.startsWith(pendingInputKeyPrefix);
    final labelByKey = {
      for (final attr in widget.availableAttributes) attr.key.trim(): attr.label
    };
    final typeByKey = {
      for (final attr in widget.availableAttributes)
        attr.key.trim(): _mapMetadataType(attr.type)
    };
    final optionKeys = <String>[
      ...widget.availableAttributes.map((e) => e.key.trim()).where(
            (k) =>
                k.isNotEmpty &&
                (k == currentKey || !widget.reservedKeys.contains(k)),
          )
    ];
    if (currentKey.isNotEmpty &&
        !isPendingInputKey &&
        !optionKeys.contains(currentKey)) {
      optionKeys.insert(0, currentKey);
    }

    return GestureDetector(
      onLongPress: widget.canRemove ? widget.onRemove : null,
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppTheme.panelSoft,
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1),
                  border:
                      Border.all(color: const Color(0xFF6D789A), width: 0.8),
                ),
                child: hasAttributeDropdown
                    ? DropdownButtonFormField<String>(
                        value:
                            optionKeys.contains(currentKey) ? currentKey : null,
                        isDense: true,
                        isExpanded: true,
                        icon: const Icon(
                          Icons.keyboard_arrow_down,
                          size: 12,
                          color: AppTheme.textMuted,
                        ),
                        dropdownColor: AppTheme.panelSoft,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'select_output',
                          hintStyle: TextStyle(fontSize: 10),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        ),
                        items: optionKeys
                            .map(
                              (key) => DropdownMenuItem<String>(
                                value: key,
                                child: Text(
                                  key,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          final mappedType =
                              typeByKey[value] ?? widget.entry.type;
                          widget.onChanged(
                            widget.entry.copyWith(
                              key: value,
                              type: mappedType,
                              label: labelByKey[value] ?? widget.entry.label,
                            ),
                          );
                        },
                      )
                    : TextField(
                        controller: _keyCtrl,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'field_name',
                          hintStyle: TextStyle(fontSize: 10),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 6),
            IgnorePointer(
              ignoring: widget.lockTypeFromAttributes && hasAttributeDropdown,
              child: Opacity(
                opacity: widget.lockTypeFromAttributes && hasAttributeDropdown
                    ? 0.65
                    : 1,
                child: _TypePill(
                  type: widget.entry.type,
                  onChanged: (type) =>
                      widget.onChanged(widget.entry.copyWith(type: type)),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: widget.canRemove
                  ? 'Remove column'
                  : 'At least one column is required',
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              splashRadius: 16,
              onPressed: widget.canRemove ? widget.onRemove : null,
              icon: Icon(
                Icons.delete_outline,
                color: widget.canRemove ? AppTheme.danger : AppTheme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  DataType _mapMetadataType(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'number':
        return DataType.number;
      case 'decimal':
        return DataType.decimal;
      case 'bool':
      case 'boolean':
        return DataType.boolean;
      case 'date':
      case 'datetime':
        return DataType.string;
      case 'string':
      default:
        return DataType.string;
    }
  }
}

class _TypePill extends StatelessWidget {
  final DataType type;
  final ValueChanged<DataType> onChanged;

  const _TypePill({required this.type, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final label = _labelFor(type);
    return PopupMenuButton<DataType>(
      onSelected: onChanged,
      color: AppTheme.panelSoft,
      itemBuilder: (_) => const [
        PopupMenuItem(
            value: DataType.string,
            child: Text('STRING', style: TextStyle(fontSize: 12))),
        PopupMenuItem(
            value: DataType.number,
            child: Text('INTEGER', style: TextStyle(fontSize: 12))),
        PopupMenuItem(
            value: DataType.decimal,
            child: Text('DECIMAL', style: TextStyle(fontSize: 12))),
        PopupMenuItem(
            value: DataType.boolean,
            child: Text('BOOLEAN', style: TextStyle(fontSize: 12))),
      ],
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(2),
          color: const Color(0xFF1A274B),
          border: Border.all(color: AppTheme.border),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: Color(0xFF8CCBFF),
          ),
        ),
      ),
    );
  }

  String _labelFor(DataType type) {
    switch (type) {
      case DataType.string:
        return 'STR';
      case DataType.number:
        return 'INT';
      case DataType.decimal:
        return 'DEC';
      case DataType.boolean:
        return 'BOOL';
    }
  }
}

Map<String, dynamic> _renameRuleKey(
  Map<String, dynamic> source,
  String oldKey,
  String newKey,
) {
  final map = Map<String, dynamic>.from(source);
  if (oldKey == newKey) {
    return map;
  }
  final previous = map.remove(oldKey);
  if (newKey.isNotEmpty) {
    map[newKey] = previous ?? '';
  }
  return map;
}

String _nextFieldName(List<String> existingKeys, String base) {
  final keys = existingKeys.toSet();
  if (!keys.contains(base)) {
    return base;
  }
  var i = 1;
  while (keys.contains('$base$i')) {
    i++;
  }
  return '$base$i';
}
