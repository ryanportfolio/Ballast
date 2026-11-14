class Transactions::BulkDeletionsController < ApplicationController
  def create
    # Exclude split children from bulk delete - they must be deleted via unsplit on parent
    # Only accounts the user may write to (none for a guest)
    entries_scope = Current.family.entries
                      .where(account_id: Current.family.accounts.writable_by(Current.user).select(:id))
                      .where(parent_entry_id: nil)
    destroyed = entries_scope.destroy_by(id: bulk_delete_params[:entry_ids])
    destroyed.map(&:account).uniq.each(&:sync_later)
    redirect_back_or_to transactions_url, notice: "#{destroyed.count} transaction#{destroyed.count == 1 ? "" : "s"} deleted"
  end

  private
    def bulk_delete_params
      params.require(:bulk_delete).permit(entry_ids: [])
    end
end
