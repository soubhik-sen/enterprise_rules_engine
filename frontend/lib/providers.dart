import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:universal_html/html.dart' as html;
import 'api_client.dart';
import 'models.dart';

enum ObjectTypeOrigin {
  explicit,
  inferred,
  missing,
}

enum ObjectTypeWarningReason {
  loadedWithoutObjectType,
  saveAttemptWithoutObjectType,
}

class AttributeMetadataCacheEntry {
  final List<AttributeMetadata> rows;
  final int schemaRevision;

  const AttributeMetadataCacheEntry({
    required this.rows,
    required this.schemaRevision,
  });
}

const String _onboardingHintsStorageKey =
    'ifthen_decision_studio_onboarding_hidden_v1';

bool _isOnboardingHintsHidden() {
  try {
    return html.window.localStorage[_onboardingHintsStorageKey] == '1';
  } catch (_) {
    return false;
  }
}

void _persistOnboardingHintsHidden(bool hidden) {
  try {
    if (hidden) {
      html.window.localStorage[_onboardingHintsStorageKey] = '1';
    } else {
      html.window.localStorage.remove(_onboardingHintsStorageKey);
    }
  } catch (_) {
    // Ignore storage failures in unsupported environments.
  }
}

final persistedTableProvider = StateProvider<RuleTable>((ref) {
  return RuleTable.empty();
});

final isLoadedTableProvider = StateProvider<bool>((ref) => false);

final showOnboardingHintsProvider =
    StateProvider<bool>((ref) => !_isOnboardingHintsHidden());

final dismissOnboardingHintsActionProvider = Provider<void Function()>((ref) {
  return () {
    ref.read(showOnboardingHintsProvider.notifier).state = false;
    _persistOnboardingHintsHidden(true);
  };
});

final objectTypeOriginProvider =
    StateProvider<ObjectTypeOrigin>((ref) => ObjectTypeOrigin.missing);

final objectTypeWarningReasonProvider =
    StateProvider<ObjectTypeWarningReason?>((ref) => null);

final uiBrightnessProvider =
    StateProvider<Brightness>((ref) => Brightness.dark);

final draftTableProvider = StateProvider<RuleTable>((ref) {
  final persisted = ref.watch(persistedTableProvider);
  return persisted;
});

final apiClientProvider = Provider<RuleApiClient>((ref) {
  return RuleApiClient();
});

final inputAttributeOptionsProvider =
    StateProvider<List<AttributeMetadata>>((ref) => const []);
final isLoadingInputAttributeOptionsProvider =
    StateProvider<bool>((ref) => false);
final inputAttributeOptionsErrorProvider =
    StateProvider<String?>((ref) => null);

final attributeMetadataCacheProvider =
    StateProvider<Map<String, AttributeMetadataCacheEntry>>((ref) => const {});

final objectTypeSchemaRevisionProvider =
    StateProvider<Map<String, int>>((ref) => const {});

final bumpObjectTypeSchemaRevisionProvider =
    Provider<void Function(String)>((ref) {
  return (objectType) {
    final normalized = objectType.trim().toUpperCase();
    if (normalized.isEmpty) return;
    final current = Map<String, int>.from(
      ref.read(objectTypeSchemaRevisionProvider),
    );
    current[normalized] = (current[normalized] ?? 0) + 1;
    ref.read(objectTypeSchemaRevisionProvider.notifier).state = current;
  };
});

final loadInputAttributeOptionsActionProvider = Provider<
    Future<List<AttributeMetadata>> Function(String,
        {bool forceRefresh})>((ref) {
  return (objectType, {bool forceRefresh = false}) async {
    final normalized = objectType.trim().toUpperCase();
    if (normalized.isEmpty) {
      return const <AttributeMetadata>[];
    }
    final revisionMap = ref.read(objectTypeSchemaRevisionProvider);
    final schemaRevision = revisionMap[normalized] ?? 0;
    final cache = ref.read(attributeMetadataCacheProvider);
    final cached = cache[normalized];
    if (!forceRefresh && cached != null) {
      if (cached.schemaRevision == schemaRevision) {
        ref.read(inputAttributeOptionsProvider.notifier).state = cached.rows;
        return cached.rows;
      }
    }
    ref.read(isLoadingInputAttributeOptionsProvider.notifier).state = true;
    ref.read(inputAttributeOptionsErrorProvider.notifier).state = null;
    try {
      final rows = await ref.read(apiClientProvider).fetchAttributeMetadata(
            objectType: normalized,
          );
      final nextCache = Map<String, AttributeMetadataCacheEntry>.from(cache);
      nextCache[normalized] = AttributeMetadataCacheEntry(
        rows: rows,
        schemaRevision: schemaRevision,
      );
      ref.read(attributeMetadataCacheProvider.notifier).state = nextCache;
      ref.read(inputAttributeOptionsProvider.notifier).state = rows;
      return rows;
    } on ApiException catch (e) {
      ref.read(inputAttributeOptionsErrorProvider.notifier).state = e.message;
      rethrow;
    } catch (e) {
      final message = 'Failed to load input attributes: $e';
      ref.read(inputAttributeOptionsErrorProvider.notifier).state = message;
      throw ApiException(message);
    } finally {
      ref.read(isLoadingInputAttributeOptionsProvider.notifier).state = false;
    }
  };
});

final isSavingProvider = StateProvider<bool>((ref) => false);
final saveErrorProvider = StateProvider<String?>((ref) => null);

class SimulationResult {
  final Map<String, dynamic>? result;
  final String? error;
  final List<String> matchedRuleIds;
  final List<Map<String, dynamic>> trace;

  SimulationResult({
    this.result,
    this.error,
    this.matchedRuleIds = const [],
    this.trace = const [],
  });
}

final simulationResultProvider =
    StateProvider<SimulationResult?>((ref) => null);

final hasUnsavedChangesProvider = Provider<bool>((ref) {
  final draft = ref.watch(draftTableProvider);
  final persisted = ref.watch(persistedTableProvider);
  return !_tablesEqual(draft, persisted);
});

// Action to save draft to backend and persisted state
final saveTableActionProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final draft = ref.read(draftTableProvider);
    final validationError = _validateBeforeSave(draft);
    if (validationError != null) {
      if (validationError == 'Object type is required.') {
        ref.read(objectTypeWarningReasonProvider.notifier).state =
            ObjectTypeWarningReason.saveAttemptWithoutObjectType;
      }
      ref.read(saveErrorProvider.notifier).state = validationError;
      throw ApiException(validationError);
    }

    ref.read(isSavingProvider.notifier).state = true;
    ref.read(saveErrorProvider.notifier).state = null;
    try {
      final saved = await ref.read(apiClientProvider).saveTable(draft);
      ref.read(persistedTableProvider.notifier).state = saved;
      ref.read(draftTableProvider.notifier).state = saved;
      ref.read(objectTypeOriginProvider.notifier).state =
          saved.objectType.trim().isEmpty
              ? ObjectTypeOrigin.missing
              : ObjectTypeOrigin.explicit;
      ref.read(objectTypeWarningReasonProvider.notifier).state = null;
    } on ApiException catch (e) {
      ref.read(saveErrorProvider.notifier).state = e.message;
      rethrow;
    } catch (e) {
      ref.read(saveErrorProvider.notifier).state = 'Save failed: $e';
      rethrow;
    } finally {
      ref.read(isSavingProvider.notifier).state = false;
    }
  };
});

final loadTableBySlugActionProvider =
    Provider<Future<void> Function(String)>((ref) {
  return (slug) async {
    ref.read(saveErrorProvider.notifier).state = null;
    try {
      final api = ref.read(apiClientProvider);
      final loaded = await api.fetchTableBySlug(slug);
      final hydrated = await _hydrateLoadedObjectType(
        table: loaded,
        fetchAttributes: ref.read(loadInputAttributeOptionsActionProvider),
      );
      ref.read(inputAttributeOptionsProvider.notifier).state = hydrated.$2;
      ref.read(persistedTableProvider.notifier).state = hydrated.$1;
      ref.read(draftTableProvider.notifier).state = hydrated.$1;
      ref.read(objectTypeOriginProvider.notifier).state = hydrated.$3;
      ref.read(objectTypeWarningReasonProvider.notifier).state =
          hydrated.$3 == ObjectTypeOrigin.missing &&
                  hydrated.$1.rules.isNotEmpty
              ? ObjectTypeWarningReason.loadedWithoutObjectType
              : null;
      ref.read(isLoadedTableProvider.notifier).state = true;
    } on ApiException catch (e) {
      ref.read(saveErrorProvider.notifier).state = e.message;
      rethrow;
    } catch (e) {
      ref.read(saveErrorProvider.notifier).state = 'Load failed: $e';
      rethrow;
    }
  };
});

// Action to discard changes
final discardChangesActionProvider = Provider((ref) {
  return () {
    final persisted = ref.read(persistedTableProvider);
    ref.read(draftTableProvider.notifier).state = persisted;
    ref.read(objectTypeOriginProvider.notifier).state =
        persisted.objectType.trim().isEmpty
            ? ObjectTypeOrigin.missing
            : ObjectTypeOrigin.explicit;
    ref.read(objectTypeWarningReasonProvider.notifier).state =
        persisted.objectType.trim().isEmpty && persisted.rules.isNotEmpty
            ? ObjectTypeWarningReason.loadedWithoutObjectType
            : null;
  };
});

final resetWorkspaceActionProvider = Provider((ref) {
  return () {
    final fresh = RuleTable.empty();
    ref.read(persistedTableProvider.notifier).state = fresh;
    ref.read(draftTableProvider.notifier).state = fresh;
    ref.read(inputAttributeOptionsProvider.notifier).state = const [];
    ref.read(inputAttributeOptionsErrorProvider.notifier).state = null;
    ref.read(saveErrorProvider.notifier).state = null;
    ref.read(simulationResultProvider.notifier).state = null;
    ref.read(isLoadedTableProvider.notifier).state = false;
    ref.read(objectTypeOriginProvider.notifier).state =
        ObjectTypeOrigin.missing;
    ref.read(objectTypeWarningReasonProvider.notifier).state = null;
    ref.read(attributeMetadataCacheProvider.notifier).state = const {};
    ref.read(objectTypeSchemaRevisionProvider.notifier).state = const {};
  };
});

bool _tablesEqual(RuleTable a, RuleTable b) {
  final normalizedA = _normalizedTableSnapshot(a);
  final normalizedB = _normalizedTableSnapshot(b);
  return jsonEncode(normalizedA) == jsonEncode(normalizedB);
}

Map<String, dynamic> _normalizedTableSnapshot(RuleTable table) {
  final inputSchema = table.inputSchema
      .map((e) => {'key': e.key.trim(), 'type': e.type.name})
      .toList()
    ..sort((a, b) => (a['key'] as String).compareTo(b['key'] as String));
  final outputSchema = table.outputSchema
      .map((e) => {'key': e.key.trim(), 'type': e.type.name})
      .toList()
    ..sort((a, b) => (a['key'] as String).compareTo(b['key'] as String));
  final rules = table.rules
      .map(
        (r) => {
          'priority': r.priority,
          'inputs': r.inputs,
          'outputs': r.outputs,
          'backendId': r.backendId,
        },
      )
      .toList()
    ..sort((a, b) => (a['priority'] as int).compareTo(b['priority'] as int));

  return {
    'backendId': table.backendId,
    'slug': table.slug.trim(),
    'objectType': table.objectType.trim(),
    'description': table.description.trim(),
    'hitPolicy': table.hitPolicy,
    'inputSchema': inputSchema,
    'outputSchema': outputSchema,
    'rules': rules,
  };
}

String? _validateBeforeSave(RuleTable table) {
  final slug = table.slug.trim();
  if (slug.isEmpty) {
    return 'Table name is required.';
  }

  final objectType = table.objectType.trim();
  if (objectType.isEmpty) {
    return 'Object type is required.';
  }

  final slugPattern = RegExp(r'^[A-Za-z0-9_-]+$');
  if (!slugPattern.hasMatch(slug)) {
    return 'Table name can use letters, numbers, underscore, and hyphen.';
  }
  if (!slugPattern.hasMatch(objectType)) {
    return 'Object type can use letters, numbers, underscore, and hyphen.';
  }
  if (table.description.trim().length > 240) {
    return 'Description must be 240 characters or less.';
  }

  if (table.inputSchema.isEmpty) {
    return 'Add at least one input field before saving.';
  }
  if (table.outputSchema.isEmpty) {
    return 'Add at least one output field before saving.';
  }

  final inputKeys = table.inputSchema.map((e) => e.key.trim()).toList();
  final outputKeys = table.outputSchema.map((e) => e.key.trim()).toList();

  if (inputKeys.any((key) => key.isEmpty) ||
      outputKeys.any((key) => key.isEmpty)) {
    return 'Schema field names cannot be empty.';
  }
  if (inputKeys.any((key) => key.startsWith(pendingInputKeyPrefix))) {
    return 'Select a valid attribute for all input fields.';
  }

  if (inputKeys.toSet().length != inputKeys.length) {
    return 'Duplicate input field names are not allowed.';
  }
  if (outputKeys.toSet().length != outputKeys.length) {
    return 'Duplicate output field names are not allowed.';
  }

  final overlap = inputKeys.toSet().intersection(outputKeys.toSet());
  if (overlap.isNotEmpty) {
    return 'Input and output field names must be distinct.';
  }

  return null;
}

Future<(RuleTable, List<AttributeMetadata>, ObjectTypeOrigin)>
    _hydrateLoadedObjectType({
  required RuleTable table,
  required Future<List<AttributeMetadata>> Function(String, {bool forceRefresh})
      fetchAttributes,
}) async {
  final normalizedObjectType = table.objectType.trim().toUpperCase();
  final inputKeys = table.inputSchema
      .map((e) => e.key.trim().toLowerCase())
      .where((k) => k.isNotEmpty)
      .toSet();

  if (normalizedObjectType.isEmpty) {
    final inferred = _inferObjectTypeFromTable(table, inputKeys);
    if (inferred != null) {
      try {
        final attrs = await fetchAttributes(inferred);
        return (
          table.copyWith(objectType: inferred),
          attrs,
          ObjectTypeOrigin.inferred,
        );
      } catch (_) {
        return (
          table.copyWith(objectType: inferred),
          const <AttributeMetadata>[],
          ObjectTypeOrigin.inferred,
        );
      }
    }
    return (
      table.copyWith(objectType: ''),
      const <AttributeMetadata>[],
      ObjectTypeOrigin.missing,
    );
  }

  if (supportedObjectTypes.contains(normalizedObjectType)) {
    try {
      final attrs = await fetchAttributes(normalizedObjectType);
      return (
        table.copyWith(objectType: normalizedObjectType),
        attrs,
        ObjectTypeOrigin.explicit,
      );
    } catch (_) {
      return (
        table.copyWith(objectType: normalizedObjectType),
        const <AttributeMetadata>[],
        ObjectTypeOrigin.explicit,
      );
    }
  }

  if (inputKeys.isEmpty) {
    return (
      table.copyWith(objectType: ''),
      const <AttributeMetadata>[],
      ObjectTypeOrigin.missing,
    );
  }

  final matches = <(String, List<AttributeMetadata>)>[];
  for (final candidate in supportedObjectTypes) {
    try {
      final attrs = await fetchAttributes(candidate);
      final keys = attrs
          .map((e) => e.key.trim().toLowerCase())
          .where((k) => k.isNotEmpty)
          .toSet();
      final isMatch = inputKeys.every(keys.contains);
      if (isMatch) {
        matches.add((candidate, attrs));
      }
    } catch (_) {
      // Ignore unavailable metadata services during inference.
    }
  }

  if (matches.length == 1) {
    return (
      table.copyWith(objectType: matches.first.$1),
      matches.first.$2,
      ObjectTypeOrigin.inferred,
    );
  }
  return (
    table.copyWith(objectType: ''),
    const <AttributeMetadata>[],
    ObjectTypeOrigin.missing,
  );
}

String? _inferObjectTypeFromTable(
  RuleTable table,
  Set<String> inputKeys,
) {
  final slug = table.slug.trim().toLowerCase();
  if (slug.contains('purchase_order') ||
      slug.startsWith('po_') ||
      slug.contains('po_') ||
      slug.contains('purchaseorder')) {
    return 'PURCHASE_ORDER';
  }
  if (slug.contains('shipment')) {
    return 'SHIPMENT';
  }
  if (inputKeys.contains('purchase_order_number') ||
      inputKeys.contains('po_number')) {
    return 'PURCHASE_ORDER';
  }
  if (inputKeys.contains('shipment_number')) {
    return 'SHIPMENT';
  }
  return null;
}
