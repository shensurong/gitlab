<script>
import successSvg from 'icons/_icon_status_success.svg';
import warningSvg from 'icons/_icon_status_warning.svg';
import simplePoll from '~/lib/utils/simple_poll';
import MergeRequest from '../../../merge_request';
import Flash from '../../../flash';
import statusIcon from '../mr_widget_status_icon.vue';
import eventHub from '../../event_hub';
import SquashBeforeMerge from './squash_before_merge.vue';

export default {
  name: 'ReadyToMerge',
  components: {
    statusIcon,
    'squash-before-merge': SquashBeforeMerge,
  },
  props: {
    mr: { type: Object, required: true },
    service: { type: Object, required: true },
  },
  data() {
    return {
      removeSourceBranch: this.mr.shouldRemoveSourceBranch,
      mergeWhenBuildSucceeds: false,
      useCommitMessageWithDescription: false,
      setToMergeWhenPipelineSucceeds: false,
      showCommitMessageEditor: false,
      isMakingRequest: false,
      isMergingImmediately: false,
      commitMessage: this.mr.commitMessage,
      successSvg,
      warningSvg,
    };
  },
  computed: {
    shouldShowMergeWhenPipelineSucceedsText() {
      return this.mr.isPipelineActive;
    },
    commitMessageLinkTitle() {
      const withDesc = 'Include description in commit message';
      const withoutDesc = "Don't include description in commit message";

      return this.useCommitMessageWithDescription ? withoutDesc : withDesc;
    },
    status() {
      const { pipeline, isPipelineActive, isPipelineFailed, hasCI, ciStatus } = this.mr;

      if (hasCI && !ciStatus) {
        return 'failed';
      } else if (!pipeline) {
        return 'success';
      } else if (isPipelineActive) {
        return 'pending';
      } else if (isPipelineFailed) {
        return 'failed';
      }

      return 'success';
    },
    mergeButtonClass() {
      const defaultClass = 'btn btn-sm btn-success accept-merge-request';
      const failedClass = `${defaultClass} btn-danger`;
      const inActionClass = `${defaultClass} btn-info`;

      if (this.status === 'failed') {
        return failedClass;
      } else if (this.status === 'pending') {
        return inActionClass;
      }

      return defaultClass;
    },
    iconClass() {
      if (
        this.status === 'failed' ||
        !this.commitMessage.length ||
        !this.mr.isMergeAllowed ||
        this.mr.preventMerge
      ) {
        return 'warning';
      }
      return 'success';
    },
    mergeButtonText() {
      if (this.isMergingImmediately) {
        return '合并进行中';
      } else if (this.shouldShowMergeWhenPipelineSucceedsText) {
        return '当流水线成功后合并';
      }

      return '合并';
    },
    shouldShowMergeOptionsDropdown() {
      return this.mr.isPipelineActive && !this.mr.onlyAllowMergeIfPipelineSucceeds;
    },
    isMergeButtonDisabled() {
      const { commitMessage } = this;
      return Boolean(
        !commitMessage.length ||
          !this.shouldShowMergeControls() ||
          this.isMakingRequest ||
          this.mr.preventMerge,
      );
    },
    isRemoveSourceBranchButtonDisabled() {
      return this.isMergeButtonDisabled;
    },
    shouldShowSquashBeforeMerge() {
      const { commitsCount, enableSquashBeforeMerge } = this.mr;
      return enableSquashBeforeMerge && commitsCount > 1;
    },
  },
  created() {
    eventHub.$on('MRWidgetUpdateSquash', this.handleUpdateSquash);
  },
  beforeDestroy() {
    eventHub.$off('MRWidgetUpdateSquash', this.handleUpdateSquash);
  },
  methods: {
    shouldShowMergeControls() {
      return this.mr.isMergeAllowed || this.shouldShowMergeWhenPipelineSucceedsText;
    },
    updateCommitMessage() {
      const cmwd = this.mr.commitMessageWithDescription;
      this.useCommitMessageWithDescription = !this.useCommitMessageWithDescription;
      this.commitMessage = this.useCommitMessageWithDescription ? cmwd : this.mr.commitMessage;
    },
    toggleCommitMessageEditor() {
      this.showCommitMessageEditor = !this.showCommitMessageEditor;
    },
    handleMergeButtonClick(mergeWhenBuildSucceeds, mergeImmediately) {
      // TODO: Remove no-param-reassign
      if (mergeWhenBuildSucceeds === undefined) {
        mergeWhenBuildSucceeds = this.mr.isPipelineActive; // eslint-disable-line no-param-reassign
      } else if (mergeImmediately) {
        this.isMergingImmediately = true;
      }

      this.setToMergeWhenPipelineSucceeds = mergeWhenBuildSucceeds === true;

      const options = {
        sha: this.mr.sha,
        commit_message: this.commitMessage,
        merge_when_pipeline_succeeds: this.setToMergeWhenPipelineSucceeds,
        should_remove_source_branch: this.removeSourceBranch === true,
        squash: this.mr.squash,
      };

      this.isMakingRequest = true;
      this.service
        .merge(options)
        .then(res => res.data)
        .then(data => {
          const hasError = data.status === 'failed' || data.status === 'hook_validation_error';

          if (data.status === 'merge_when_pipeline_succeeds') {
            eventHub.$emit('MRWidgetUpdateRequested');
          } else if (data.status === 'success') {
            this.initiateMergePolling();
          } else if (hasError) {
            eventHub.$emit('FailedToMerge', data.merge_error);
          }
        })
        .catch(() => {
          this.isMakingRequest = false;
          new Flash('出现了错误。请重试。'); // eslint-disable-line
        });
    },
    handleUpdateSquash(val) {
      this.mr.squash = val;
    },
    initiateMergePolling() {
      simplePoll((continuePolling, stopPolling) => {
        this.handleMergePolling(continuePolling, stopPolling);
      });
    },
    handleMergePolling(continuePolling, stopPolling) {
      this.service
        .poll()
        .then(res => res.data)
        .then(data => {
          if (data.state === 'merged') {
            // If state is merged we should update the widget and stop the polling
            eventHub.$emit('MRWidgetUpdateRequested');
            eventHub.$emit('FetchActionsContent');
            MergeRequest.setStatusBoxToMerged();
            MergeRequest.hideCloseButton();
            MergeRequest.decreaseCounter();
            stopPolling();

            // If user checked remove source branch and we didn't remove the branch yet
            // we should start another polling for source branch remove process
            if (this.removeSourceBranch && data.source_branch_exists) {
              this.initiateRemoveSourceBranchPolling();
            }
          } else if (data.merge_error) {
            eventHub.$emit('FailedToMerge', data.merge_error);
            stopPolling();
          } else {
            // MR is not merged yet, continue polling until the state becomes 'merged'
            continuePolling();
          }
        })
        .catch(() => {
          new Flash('合并出现了错误。请重试。'); // eslint-disable-line
        });
    },
    initiateRemoveSourceBranchPolling() {
      // We need to show source branch is being removed spinner in another component
      eventHub.$emit('SetBranchRemoveFlag', [true]);

      simplePoll((continuePolling, stopPolling) => {
        this.handleRemoveBranchPolling(continuePolling, stopPolling);
      });
    },
    handleRemoveBranchPolling(continuePolling, stopPolling) {
      this.service
        .poll()
        .then(res => res.data)
        .then(data => {
          // If source branch exists then we should continue polling
          // because removing a source branch is a background task and takes time
          if (data.source_branch_exists) {
            continuePolling();
          } else {
            // Branch is removed. Update widget, stop polling and hide the spinner
            eventHub.$emit('MRWidgetUpdateRequested', () => {
              eventHub.$emit('SetBranchRemoveFlag', [false]);
            });
            stopPolling();
          }
        })
        .catch(() => {
          new Flash('删除源分支出现了错误，请重试。'); // eslint-disable-line
        });
    },
  },
};
</script>

<template>
  <div class="mr-widget-body media">
    <status-icon :status="iconClass" />
    <div class="media-body">
      <div class="mr-widget-body-controls media space-children">
        <span class="btn-group">
          <button
            :disabled="isMergeButtonDisabled"
            :class="mergeButtonClass"
            type="button"
            class="qa-merge-button"
            @click="handleMergeButtonClick();"
          >
            <i v-if="isMakingRequest" class="fa fa-spinner fa-spin" aria-hidden="true"></i>
            {{ mergeButtonText }}
          </button>
          <button
            v-if="shouldShowMergeOptionsDropdown"
            :disabled="isMergeButtonDisabled"
            type="button"
            class="btn btn-sm btn-info dropdown-toggle js-merge-moment"
            data-toggle="dropdown"
            aria-label="Select merge moment"
          >
            <i class="fa fa-chevron-down qa-merge-moment-dropdown" aria-hidden="true"></i>
          </button>
          <ul
            v-if="shouldShowMergeOptionsDropdown"
            class="dropdown-menu dropdown-menu-right"
            role="menu"
          >
            <li>
              <a
                class="merge_when_pipeline_succeeds qa-merge-when-pipeline-succeeds-option"
                href="#"
                @click.prevent="handleMergeButtonClick(true);"
              >
                <span class="media">
                  <span class="merge-opt-icon" aria-hidden="true" v-html="successSvg"></span>
                  <span class="media-body merge-opt-title">Merge when pipeline succeeds</span>
                </span>
              </a>
            </li>
            <li>
              <a
                class="accept-merge-request qa-merge-immediately-option"
                href="#"
                @click.prevent="handleMergeButtonClick(false, true);"
              >
                <span class="media">
                  <span class="merge-opt-icon" aria-hidden="true" v-html="warningSvg"></span>
                  <span class="media-body merge-opt-title">Merge immediately</span>
                </span>
              </a>
            </li>
          </ul>
        </span>
        <div class="media-body-wrap space-children">
          <template v-if="shouldShowMergeControls()">
            <label v-if="mr.canRemoveSourceBranch">
              <input
                id="remove-source-branch-input"
                v-model="removeSourceBranch"
                :disabled="isRemoveSourceBranchButtonDisabled"
                class="js-remove-source-branch-checkbox"
                type="checkbox"
              />
              Remove source branch
            </label>

            <!-- Placeholder for EE extension of this component -->
            <squash-before-merge
              v-if="shouldShowSquashBeforeMerge"
              :mr="mr"
              :is-merge-button-disabled="isMergeButtonDisabled"
            />

            <span v-if="mr.ffOnlyEnabled" class="js-fast-forward-message">
              无合并提交的快进式合并
            </span>
            <button
              v-else
              :disabled="isMergeButtonDisabled"
              class="js-modify-commit-message-button btn btn-default btn-sm"
              type="button"
              @click="toggleCommitMessageEditor"
            >
              修改提交信息
            </button>
          </template>
          <template v-else>
            <span class="bold js-resolve-mr-widget-items-message">
              您只能在上述问题都解决后才能合并
            </span>
          </template>
        </div>
      </div>
      <div v-if="showCommitMessageEditor" class="prepend-top-default commit-message-editor">
        <div class="form-group clearfix">
          <label class="col-form-label" for="commit-message"> 提交信息 </label>
          <div class="col-sm-10">
            <div class="commit-message-container">
              <div class="max-width-marker"></div>
              <textarea
                id="commit-message"
                v-model="commitMessage"
                class="form-control js-commit-message"
                required="required"
                rows="14"
                name="提交信息"
              ></textarea>
            </div>
            <p class="hint">
              尝试保持第一行不超过52个字符，其它行不超过72个字符。
            </p>
            <div class="hint">
              <a href="#" @click.prevent="updateCommitMessage"> {{ commitMessageLinkTitle }} </a>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
