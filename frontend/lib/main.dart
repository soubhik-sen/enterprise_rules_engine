import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'api_client.dart';
import 'app_theme.dart';
import 'models.dart';
import 'providers.dart';
import 'schema_wizard.dart';
import 'rule_grid.dart';
import 'simulator.dart';
import 'table_io.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brightness = ref.watch(uiBrightnessProvider);
    return MaterialApp(
      title: 'Thenif Decision Studio',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme(context),
      darkTheme: AppTheme.darkTheme(context),
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: const EnterpriseStudio(),
    );
  }
}

class EnterpriseStudio extends ConsumerWidget {
  const EnterpriseStudio({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(draftTableProvider);
    final persisted = ref.watch(persistedTableProvider);
    final isLoadedFromDb = ref.watch(isLoadedTableProvider);
    final isDirty = ref.watch(hasUnsavedChangesProvider);
    final isSaving = ref.watch(isSavingProvider);
    final objectTypeOrigin = ref.watch(objectTypeOriginProvider);
    final objectTypeWarningReason = ref.watch(objectTypeWarningReasonProvider);
    final uiBrightness = ref.watch(uiBrightnessProvider);
    final showOnboardingHints = ref.watch(showOnboardingHintsProvider);
    final apiClient = ref.read(apiClientProvider);
    final tableIo = TableIo(apiClient);

    // Listen for simulation errors
    ref.listen(simulationResultProvider, (previous, next) {
      if (next?.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next!.error!),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });

    ref.listen(saveErrorProvider, (previous, next) {
      if (next != null && next.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });

    final studioContent = SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0B1430), Color(0xFF050A1C)],
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            _TopBar(
              draftName: draft.name,
              objectType: draft.objectType.trim(),
              objectTypeOrigin: objectTypeOrigin,
              uiBrightness: uiBrightness,
              isDirty: isDirty,
              isSaving: isSaving,
              onToggleBrightness: () {
                final next = uiBrightness == Brightness.dark
                    ? Brightness.light
                    : Brightness.dark;
                ref.read(uiBrightnessProvider.notifier).state = next;
              },
              onLoad: () async {
                final table = await showDialog<TableSummary>(
                  context: context,
                  builder: (_) => _TableSearchDialog(apiClient: apiClient),
                );
                if (table == null) return;

                try {
                  await ref.read(loadTableBySlugActionProvider)(table.slug);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text("Loaded '${table.slug}'"),
                      backgroundColor: const Color(0xFF3554D1),
                    ),
                  );
                } catch (_) {}
              },
              onUpload: () async {
                try {
                  final imported =
                      await tableIo.uploadRulesFromFile(draft: draft);
                  if (imported == null) return;

                  final issues = <String>[...imported.parseErrors];
                  final importedObjectType = imported.objectType.trim();
                  final draftObjectType = draft.objectType.trim();
                  var effectiveObjectType = draftObjectType;
                  if (draftObjectType.isNotEmpty &&
                      !supportedObjectTypes.contains(draftObjectType)) {
                    issues.add(
                      'Current table object type "$draftObjectType" is unsupported. Allowed values: ${supportedObjectTypes.join(', ')}.',
                    );
                  }
                  if (importedObjectType.isNotEmpty) {
                    if (!supportedObjectTypes.contains(importedObjectType)) {
                      issues.add(
                        'Imported file object type "$importedObjectType" is unsupported. Allowed values: ${supportedObjectTypes.join(', ')}.',
                      );
                    }
                    if (draftObjectType.isNotEmpty &&
                        draftObjectType != importedObjectType) {
                      issues.add(
                        'Imported file object type "$importedObjectType" does not match current table object type "$draftObjectType".',
                      );
                    } else {
                      effectiveObjectType = importedObjectType;
                    }
                  }
                  if (effectiveObjectType.isEmpty) {
                    issues.add(
                      'Select an object type before importing rules.',
                    );
                  } else if (!supportedObjectTypes
                      .contains(effectiveObjectType)) {
                    issues.add(
                      'Object type "$effectiveObjectType" is unsupported. Allowed values: ${supportedObjectTypes.join(', ')}.',
                    );
                  }

                  final importedDraft = draft.copyWith(
                    objectType: effectiveObjectType,
                    inputSchema: imported.inputSchema,
                    outputSchema: imported.outputSchema,
                  );

                  if (importedDraft.inputSchema.isEmpty) {
                    issues.add(
                      'No input schema found after import. Add input columns or prefix input headers with "in:".',
                    );
                  }
                  if (importedDraft.outputSchema.isEmpty) {
                    issues.add(
                      'No output schema found after import. Add output columns or prefix output headers with "out:".',
                    );
                  }
                  final inputKeys = importedDraft.inputSchema
                      .map((e) => e.key.trim())
                      .where((k) => k.isNotEmpty)
                      .toList();
                  final outputKeys = importedDraft.outputSchema
                      .map((e) => e.key.trim())
                      .where((k) => k.isNotEmpty)
                      .toList();
                  final duplicateInputs = inputKeys
                      .where((k) =>
                          inputKeys.where((other) => other == k).length > 1)
                      .toSet()
                      .toList();
                  final duplicateOutputs = outputKeys
                      .where((k) =>
                          outputKeys.where((other) => other == k).length > 1)
                      .toSet()
                      .toList();
                  if (duplicateInputs.isNotEmpty) {
                    issues.add(
                      'Duplicate input attributes found: ${duplicateInputs.join(', ')}.',
                    );
                  }
                  if (duplicateOutputs.isNotEmpty) {
                    issues.add(
                      'Duplicate output attributes found: ${duplicateOutputs.join(', ')}.',
                    );
                  }
                  final overlap =
                      inputKeys.toSet().intersection(outputKeys.toSet());
                  if (overlap.isNotEmpty) {
                    issues.add(
                      'Input and output attributes must be distinct: ${overlap.join(', ')}.',
                    );
                  }

                  List<AttributeMetadata> metadata = const [];
                  if (issues.isEmpty) {
                    metadata =
                        await ref.read(loadInputAttributeOptionsActionProvider)(
                      effectiveObjectType,
                    );
                    final allowedInputKeys = metadata
                        .map((e) => e.key.trim())
                        .where((k) => k.isNotEmpty)
                        .toSet();
                    final invalidInputs = importedDraft.inputSchema
                        .map((e) => e.key.trim())
                        .where(
                          (k) => k.isNotEmpty && !allowedInputKeys.contains(k),
                        )
                        .toSet()
                        .toList();
                    if (invalidInputs.isNotEmpty) {
                      issues.add(
                        'Input schema has attributes outside object type "$effectiveObjectType": ${invalidInputs.join(', ')}.',
                      );
                    }
                  }

                  if (issues.isEmpty) {
                    final consistency = await apiClient.checkRulesConsistency(
                      draft: importedDraft,
                      rules: imported.rules,
                    );
                    issues.addAll(
                      consistency.errors.map(
                        (e) =>
                            'Row ${e.row}${e.field == null ? '' : " (${e.field})"}: ${e.message}',
                      ),
                    );
                  }
                  if (issues.isNotEmpty) {
                    if (!context.mounted) return;
                    await showDialog<void>(
                      context: context,
                      builder: (_) => _ConsistencyCheckDialog(
                        title: 'Rules Consistency Check',
                        issues: issues,
                      ),
                    );
                    return;
                  }
                  ref.read(inputAttributeOptionsProvider.notifier).state =
                      metadata;
                  ref.read(draftTableProvider.notifier).state =
                      importedDraft.copyWith(rules: imported.rules);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Rules consistency check passed (0 errors). Rules loaded to draft. Click Save Changes to persist.',
                      ),
                      backgroundColor: Color(0xFF3554D1),
                    ),
                  );
                } on ApiException catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(e.message),
                      backgroundColor: AppTheme.danger,
                    ),
                  );
                }
              },
              onDownload: () async {
                try {
                  await tableIo.downloadRulesToXlsx(draft);
                } on ApiException catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(e.message),
                      backgroundColor: AppTheme.danger,
                    ),
                  );
                }
              },
              onDiscard: () => ref.read(discardChangesActionProvider)(),
              onReset: () => ref.read(resetWorkspaceActionProvider)(),
              onSave: (isDirty && !isSaving)
                  ? () async {
                      final latestDraft = ref.read(draftTableProvider);
                      if (isLoadedFromDb &&
                          persisted.backendId != null &&
                          persisted.rules.isNotEmpty &&
                          _hasInputSchemaChanged(persisted, latestDraft)) {
                        final proceed = await showDialog<bool>(
                              context: context,
                              builder: (_) =>
                                  const _SchemaChangeWarningDialog(),
                            ) ??
                            false;
                        if (!proceed) return;
                      }
                      try {
                        await ref.read(saveTableActionProvider)();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Changes saved'),
                            backgroundColor: Color(0xFF2E9B67),
                          ),
                        );
                      } catch (_) {}
                    }
                  : null,
            ),
            if (showOnboardingHints)
              _OnboardingHintsBanner(
                onDismiss: ref.read(dismissOnboardingHintsActionProvider),
              ),
            if (objectTypeWarningReason != null &&
                draft.objectType.trim().isEmpty)
              _ObjectTypeWarningBanner(
                reason: objectTypeWarningReason,
              ),
            const Divider(height: 1),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final leftWidth = constraints.maxWidth < 1600 ? 264.0 : 282.0;
                  final rightWidth =
                      constraints.maxWidth < 1600 ? 250.0 : 270.0;
                  return Row(
                    children: [
                      Container(
                        width: leftWidth,
                        decoration: const BoxDecoration(
                          color: AppTheme.panel,
                          border: Border(
                            right: BorderSide(color: AppTheme.border),
                          ),
                        ),
                        child: const Align(
                          alignment: Alignment.topLeft,
                          child: SingleChildScrollView(child: SchemaWizard()),
                        ),
                      ),
                      const Expanded(
                        child: ColoredBox(
                          color: AppTheme.bg,
                          child: RuleGrid(),
                        ),
                      ),
                      Container(
                        width: rightWidth,
                        decoration: const BoxDecoration(
                          color: AppTheme.panel,
                          border: Border(
                            left: BorderSide(color: AppTheme.border),
                          ),
                        ),
                        child: const Simulator(),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    return Scaffold(
      body: uiBrightness == Brightness.dark
          ? studioContent
          : ColorFiltered(
              colorFilter: const ColorFilter.matrix([
                -1,
                0,
                0,
                0,
                255,
                0,
                -1,
                0,
                0,
                255,
                0,
                0,
                -1,
                0,
                255,
                0,
                0,
                0,
                1,
                0,
              ]),
              child: studioContent,
            ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String draftName;
  final String objectType;
  final ObjectTypeOrigin objectTypeOrigin;
  final Brightness uiBrightness;
  final bool isDirty;
  final bool isSaving;
  final VoidCallback onToggleBrightness;
  final Future<void> Function() onLoad;
  final Future<void> Function() onUpload;
  final Future<void> Function() onDownload;
  final VoidCallback onDiscard;
  final VoidCallback onReset;
  final Future<void> Function()? onSave;

  const _TopBar({
    required this.draftName,
    required this.objectType,
    required this.objectTypeOrigin,
    required this.uiBrightness,
    required this.isDirty,
    required this.isSaving,
    required this.onToggleBrightness,
    required this.onLoad,
    required this.onUpload,
    required this.onDownload,
    required this.onDiscard,
    required this.onReset,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            SizedBox(
              width: 240,
              height: 56,
              child: ClipRect(
                child: Align(
                  alignment: Alignment.center,
                  child: Transform.scale(
                    scale: 1.44,
                    alignment: Alignment.center,
                    child: Image.asset(
                      'assets/branding/thenif_decision_studio_logo_trimmed.png',
                      height: 56,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            const VerticalDivider(width: 1, indent: 10, endIndent: 10),
            const SizedBox(width: 10),
            const Text(
              'Projects',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                size: 14, color: AppTheme.textMuted),
            const SizedBox(width: 4),
            const Expanded(
              child: Text(
                'User_Validation_Flow',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 10),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _ObjectTypeBadge(
              objectType: objectType,
              origin: objectTypeOrigin,
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: onToggleBrightness,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: AppTheme.border),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
              ),
              icon: Icon(
                uiBrightness == Brightness.dark
                    ? Icons.light_mode
                    : Icons.dark_mode,
                size: 14,
              ),
              label: Text(
                uiBrightness == Brightness.dark ? 'Light' : 'Dark',
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: onUpload,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: AppTheme.border),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.upload_file, size: 14),
              label: const Text('Upload XLSX'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: onDownload,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: AppTheme.border),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.download, size: 14),
              label: const Text('Download XLSX'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: onLoad,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: AppTheme.border),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.cloud_download, size: 14),
              label: const Text('Load Table'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: onReset,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: AppTheme.border),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.restart_alt, size: 14),
              label: const Text('Start Fresh'),
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              onPressed: isDirty ? onDiscard : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.danger,
                side: const BorderSide(color: AppTheme.danger),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Discard Changes'),
            ),
            const SizedBox(width: 6),
            ElevatedButton.icon(
              onPressed: onSave,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: Colors.white,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
                visualDensity: VisualDensity.compact,
              ),
              icon: isSaving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_rounded, size: 14),
              label: Text(isSaving ? 'Saving' : 'Save Changes'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ObjectTypeBadge extends StatelessWidget {
  final String objectType;
  final ObjectTypeOrigin origin;

  const _ObjectTypeBadge({
    required this.objectType,
    required this.origin,
  });

  @override
  Widget build(BuildContext context) {
    final label = objectType.isEmpty ? 'OBJECT TYPE: UNSET' : objectType;
    final badgeColor = switch (origin) {
      ObjectTypeOrigin.explicit => const Color(0xFF2E9B67),
      ObjectTypeOrigin.inferred => const Color(0xFFE39C2F),
      ObjectTypeOrigin.missing => const Color(0xFFB84141),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: badgeColor.withOpacity(0.16),
        border: Border.all(color: badgeColor),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(
        children: [
          Icon(
            origin == ObjectTypeOrigin.explicit
                ? Icons.verified
                : Icons.warning_amber_rounded,
            size: 12,
            color: badgeColor,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: badgeColor,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ObjectTypeWarningBanner extends StatelessWidget {
  final ObjectTypeWarningReason reason;

  const _ObjectTypeWarningBanner({
    required this.reason,
  });

  @override
  Widget build(BuildContext context) {
    final message = reason == ObjectTypeWarningReason.loadedWithoutObjectType
        ? 'Loaded table has rules but no object type. Select an object type before saving.'
        : 'Object type missing. Select an object type before saving.';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF3A2A10),
        border: Border(
          bottom: BorderSide(color: Color(0xFF6B4B18)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Color(0xFFE39C2F), size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 10, color: Color(0xFFFFD59E)),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingHintsBanner extends StatelessWidget {
  final VoidCallback onDismiss;

  const _OnboardingHintsBanner({required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF102144),
        border: Border(
          bottom: BorderSide(color: AppTheme.border),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.lightbulb_outline,
            color: AppTheme.statusChanged,
            size: 16,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Quick Start',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '1. Pick OBJECT TYPE and define INPUT/OUTPUT schema.',
                  style: TextStyle(fontSize: 9, color: AppTheme.textMuted),
                ),
                Text(
                  '2. Build rules in grid and run simulation on the right.',
                  style: TextStyle(fontSize: 9, color: AppTheme.textMuted),
                ),
                Text(
                  '3. Use Detect Changes before save to review edits.',
                  style: TextStyle(fontSize: 9, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onDismiss,
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.textMuted,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text(
              'Dismiss',
              style: TextStyle(fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConsistencyCheckDialog extends StatelessWidget {
  final String title;
  final List<String> issues;

  const _ConsistencyCheckDialog({
    required this.title,
    required this.issues,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 620,
        height: 420,
        child: issues.isEmpty
            ? const Center(
                child: Text(
                  'No errors found.',
                  style: TextStyle(color: AppTheme.textMuted),
                ),
              )
            : ListView.separated(
                itemCount: issues.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      issues[index],
                      style: const TextStyle(color: AppTheme.danger),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _TableSearchDialog extends StatefulWidget {
  const _TableSearchDialog({required this.apiClient});

  final RuleApiClient apiClient;

  @override
  State<_TableSearchDialog> createState() => _TableSearchDialogState();
}

class _TableSearchDialogState extends State<_TableSearchDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  int _requestSeq = 0;
  List<TableSummary> _tables = const [];
  final Set<String> _deletingIds = <String>{};
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_onSearchChanged);
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      _load(query: _searchCtrl.text);
    });
  }

  Future<void> _load({String? query}) async {
    final reqId = ++_requestSeq;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final rows = await widget.apiClient.listTables(search: query);
      if (!mounted || reqId != _requestSeq) return;
      setState(() {
        _tables = rows;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || reqId != _requestSeq) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _deleteTable(TableSummary table) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete Table'),
            content: Text(
              "Delete table '${table.slug}' and all its rules? This cannot be undone.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;

    setState(() => _deletingIds.add(table.id));
    try {
      await widget.apiClient.deleteTableById(table.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Deleted '${table.slug}'"),
          backgroundColor: const Color(0xFF2E9B67),
        ),
      );
      await _load(query: _searchCtrl.text);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: AppTheme.danger,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _deletingIds.remove(table.id));
      }
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Load Table'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'Search by slug or description...',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error.isNotEmpty
                      ? Center(
                          child: Text(
                            _error,
                            style: const TextStyle(color: AppTheme.danger),
                          ),
                        )
                      : _tables.isEmpty
                          ? const Center(
                              child: Text(
                                'No tables found',
                                style: TextStyle(color: AppTheme.textMuted),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _tables.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final table = _tables[index];
                                final deleting =
                                    _deletingIds.contains(table.id);
                                return ListTile(
                                  dense: true,
                                  title: Text(table.slug),
                                  subtitle: Text(
                                    table.description.isEmpty
                                        ? 'No description'
                                        : table.description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: deleting
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : IconButton(
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            size: 18,
                                            color: AppTheme.danger,
                                          ),
                                          tooltip: 'Delete table',
                                          onPressed: () => _deleteTable(table),
                                        ),
                                  onTap: deleting
                                      ? null
                                      : () => Navigator.of(context).pop(table),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _SchemaChangeWarningDialog extends StatelessWidget {
  const _SchemaChangeWarningDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Input Schema Changed'),
      content: const Text(
        'You changed input schema on a loaded table. Saving will replace old stored rules with the current draft rules. Download backup first if needed.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(backgroundColor: Colors.orangeAccent),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

bool _hasInputSchemaChanged(RuleTable baseline, RuleTable draft) {
  List<String> normalize(List<SchemaEntry> schema) {
    final normalized = schema
        .map((e) => '${e.key.trim().toLowerCase()}:${e.type.name}')
        .toList()
      ..sort();
    return normalized;
  }

  final before = normalize(baseline.inputSchema);
  final after = normalize(draft.inputSchema);
  if (before.length != after.length) return true;
  for (var i = 0; i < before.length; i++) {
    if (before[i] != after[i]) return true;
  }
  return false;
}
