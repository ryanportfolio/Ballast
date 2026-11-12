class ImportsController < ApplicationController
  include SettingsHelper

  before_action :set_import, only: %i[show publish destroy revert apply_template cancel]
  before_action :require_writable_import_accounts!, only: %i[publish revert destroy]
  before_action :reject_guest_family_config_import!, except: %i[index new show]
  before_action :require_guest_writable_created_accounts!, only: %i[revert destroy]
  before_action :reject_guest_new_categories_or_tags!, only: :publish

  def publish
    @import.publish_later

    redirect_to import_path(@import), notice: t(".started")
  rescue Import::MaxRowCountExceededError
    redirect_back_or_to import_path(@import), alert: t(".max_rows_exceeded", max: @import.max_row_count)
  end

  def cancel
    if @import.force_fail!
      redirect_to imports_path, notice: t(".cancelled")
    else
      redirect_to imports_path, alert: t(".not_cancellable")
    end
  end

  def index
    @pagy, @imports = pagy(Current.family.imports.where(type: Import::TYPES).ordered, limit: safe_per_page)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.imports"), imports_path ]
    ]
    respond_to do |format|
      format.html { render layout: "settings" }
    end
  end

  def new
    @pending_import = Current.family.imports.where(type: Import::TYPES).ordered.pending.first
  end

  def create
    file = import_params[:import_file]

    type = params.dig(:import, :type).to_s
    type = "TransactionImport" unless Import::TYPES.include?(type)

    account = accessible_accounts.find_by(id: params.dig(:import, :account_id))
    import = Current.family.imports.create!(
      type: type,
      account: account,
      date_format: Current.family.date_format,
    )

    if file.present?
      if file.size > Import::MAX_CSV_SIZE
        import.destroy
        redirect_to new_import_path, alert: t("imports.create.file_too_large", max_size: Import::MAX_CSV_SIZE / 1.megabyte)
        return
      end

      unless Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type)
        import.destroy
        redirect_to new_import_path, alert: t("imports.create.invalid_file_type")
        return
      end

      # Stream reading is not fully applicable here as we store the raw string in the DB,
      # but we have validated size beforehand to prevent memory exhaustion from massive files.
      import.update!(raw_file_str: file.read)

      redirect_to import_configuration_path(import), notice: t("imports.create.csv_uploaded")
    else
      redirect_to import_upload_path(import)
    end
  rescue ActionController::ParameterMissing
    redirect_to new_import_path, alert: t("imports.create.missing_upload")
  end

  def show
    if !@import.uploaded?
      redirect_to import_upload_path(@import), alert: t("imports.show.finalize_upload")
    elsif !@import.publishable?
      next_path = @import.mapping_steps.empty? ? import_clean_path(@import) : import_confirm_path(@import)
      redirect_to next_path, alert: t("imports.show.finalize_mappings")
    end
  end

  def revert
    @import.revert_later
    redirect_to imports_path, notice: t(".started")
  end

  def apply_template
    if @import.suggested_template
      @import.apply_template!(@import.suggested_template)
      redirect_to import_configuration_path(@import), notice: t(".template_applied")
    else
      redirect_to import_configuration_path(@import), alert: t(".no_template_found")
    end
  end

  def destroy
    @import.destroy

    redirect_to imports_path, notice: t(".deleted")
  end

  private
    def set_import
      @import = Current.family.imports.includes(:account).find(params[:id])
    end

    def import_params
      params.require(:import).permit(:import_file)
    end

    def reject_guest_family_config_import!
      type = @import ? @import.type : params.dig(:import, :type).to_s
      require_non_guest! if Import::FAMILY_CONFIG_TYPES.include?(type)
    end

    # Reverting or deleting an import also destroys the accounts it created,
    # which require_writable_import_accounts! leaves out. Guests are read-only
    # by design, so they may only do that to accounts they can write.
    def require_guest_writable_created_accounts!
      return unless Current.user.guest?

      created_ids = @import.accounts.pluck(:id)
      writable_ids = Current.family.accounts.writable_by(Current.user).where(id: created_ids).pluck(:id)
      return if (created_ids - writable_ids).empty?

      deny_import_change(t("accounts.not_authorized"), fallback: imports_path)
    end

    # Categories and tags are family-wide configuration, so a guest's import
    # must map every category and tag to an existing one (or leave it empty).
    def reject_guest_new_categories_or_tags!
      return unless Current.user.guest? && @import.creates_categories_or_tags?

      deny_import_change(t("imports.publish.guest_new_categories_or_tags"), fallback: import_confirm_path(@import))
    end

    def deny_import_change(alert, fallback:)
      respond_to do |format|
        format.html { redirect_back_or_to fallback, alert: alert }
        format.turbo_stream { head :forbidden }
        format.json { head :forbidden }
        format.any { head :forbidden }
      end
    end

    # Imports are family-scoped, so a member can reach an import configured by
    # someone else, or one whose target account was unshared since. Publishing,
    # reverting or deleting writes into its accounts, so require write access
    # to all.
    def require_writable_import_accounts!
      return if @import.accounts_writable_by?(Current.user)

      redirect_back_or_to import_path(@import), alert: t("accounts.not_authorized")
    end
end
