import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uniun/common/atoms/uniun_back_button.dart';
import 'package:uniun/common/locator.dart';
import 'package:uniun/l10n/app_localizations.dart';
import 'package:uniun/features/shiv/model_select/cubit/select_ai_model_cubit.dart';
import 'package:uniun/features/shiv/model_select/widgets/model_card.dart';
import 'package:uniun/features/shiv/model_select/widgets/model_selection_footer.dart';
import 'package:uniun/features/shiv/model_select/widgets/uniun_cloud_card.dart';
import 'package:uniun/domain/entities/llm/llm_backend_type.dart';
import 'package:uniun/features/settings/widgets/storage_card.dart' show formatStorageBytes;

class AIModelSelectionPage extends StatelessWidget {
  const AIModelSelectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => getIt<SelectAIModelCubit>(),
      child: const _AIModelSelectionView(),
    );
  }
}

class _AIModelSelectionView extends StatelessWidget {
  const _AIModelSelectionView();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return BlocConsumer<SelectAIModelCubit, SelectAIModelState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status ||
          prev.cloudErrorMessage != curr.cloudErrorMessage,
      listener: (context, state) {
        if (state.cloudErrorMessage != null) {
          final detail = state.cloudErrorMessage!;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(detail.isEmpty
                ? l10n.cloudProviderConnectFailed
                : detail),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
          ));
        }
        if (state.status == SelectAIModelStatus.done) {
          Navigator.of(context).maybePop(true);
        }
        if (state.status == SelectAIModelStatus.error &&
            state.errorMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(l10n.aiModelDownloadError),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
          ));
        }
      },
      builder: (context, state) {
        return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.surface,
            elevation: 0,
            scrolledUnderElevation: 0,
            leading: UniunBackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            title: Text(
              l10n.aiModelSelectionTitle,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            centerTitle: true,
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(1),
              child: Container(
                height: 1,
                color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 20),
                  children: [
                    Text(
                      l10n.aiModelAvailableHeader,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.aiModelSelectionSubtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // No-download path: sign in and run Shiv on UNIUN Cloud.
                    UniunCloudCard(
                      isConnecting: state.isCloudConnecting,
                      onTap: () =>
                          context.read<SelectAIModelCubit>().connectCloud(),
                    ),
                    ...state.cloudModels.map((model) => Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: CloudModelTile(
                            model: model,
                            isActive: state.activeBackend ==
                                    LlmBackendType.uniunCloud &&
                                state.activeCloudModelId == model.id,
                            isActivating:
                                state.activatingCloudModelId == model.id,
                            onTap: () => context
                                .read<SelectAIModelCubit>()
                                .activateCloudModel(model.id),
                          ),
                        )),
                    const SizedBox(height: 16),

                    ...state.models.map((model) => Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: ModelCard(
                            model: model,
                            isSelected:
                                state.selectedModelId == model.modelId,
                            // A downloaded model is only ACTIVE when the
                            // on-device backend is actually in use.
                            isActive: state.activeModelId == model.modelId &&
                                state.activeBackend ==
                                    LlmBackendType.localGemma,
                            isDownloaded: state.downloadedModelIds
                                .contains(model.modelId),
                            isDeleting:
                                state.deletingModelId == model.modelId,
                            onTap: () => context
                                .read<SelectAIModelCubit>()
                                .selectModel(model.modelId),
                            onDelete: () => context
                                .read<SelectAIModelCubit>()
                                .deleteModel(model.modelId),
                          ),
                        )),

                    const SizedBox(height: 8),

                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
                        border: Border.all(
                            color:
                                Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded,
                              size: 18, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              l10n.aiModelDownloadInfoText,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (state.orphanedFilesSizeBytes > 0) ...[
                      const SizedBox(height: 12),
                      _OrphanedFilesBanner(state: state),
                    ],
                    const SizedBox(height: 16),
                  ],
                ),
              ),
              ModelSelectionFooter(state: state),
            ],
          ),
        );
      },
    );
  }
}

/// Shown only when flutter_edge_ai reports leftover model files on disk
/// (partial downloads, or files a previous delete couldn't locate by its
/// guessed path) — a capability [AIModelRepositoryImpl.deleteModel] can't
/// catch on its own since it only knows the path of the model it was asked
/// to delete.
class _OrphanedFilesBanner extends StatelessWidget {
  const _OrphanedFilesBanner({required this.state});
  final SelectAIModelState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.05),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cleaning_services_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.aiModelOrphanedFilesText(
                  formatStorageBytes(state.orphanedFilesSizeBytes)),
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(width: 10),
          state.isCleaningUpFiles
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: scheme.primary),
                )
              : TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () async {
                    final cubit = context.read<SelectAIModelCubit>();
                    final messenger = ScaffoldMessenger.of(context);
                    final removed = await cubit.cleanupOrphanedFiles();
                    if (!context.mounted) return;
                    messenger.showSnackBar(SnackBar(
                      content: Text(removed != null
                          ? l10n.aiModelCleanUpSuccess(removed)
                          : l10n.aiModelCleanUpFailed),
                    ));
                  },
                  child: Text(
                    l10n.aiModelCleanUpAction,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
        ],
      ),
    );
  }
}
