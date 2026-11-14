module AccountAuthorizable
  extend ActiveSupport::Concern

  included do
    include StreamExtensions
  end

  private

    # Ballast has no account sharing: every member of the account's family may
    # change it and guests may not, so :write and :annotate are the same test.
    # Accounts of another family are refused too.
    def require_account_permission!(account, _level = :write, redirect_path: nil)
      return true if account.writable_by?(Current.user)

      path = redirect_path || account_path(account)
      respond_to do |format|
        format.html { redirect_back_or_to path, alert: t("accounts.not_authorized") }
        format.turbo_stream { stream_redirect_back_or_to(path, alert: t("accounts.not_authorized")) }
        format.json { render json: { error: t("accounts.not_authorized") }, status: :forbidden }
      end
      false
    end
end
