class Import::UploadsController < ApplicationController
  include ImportGuestGuardable

  layout "imports"

  before_action :set_import
  before_action :require_import_editable!, only: :update

  def show
  end

  def sample_csv
    send_data @import.csv_template.to_csv,
      filename: "#{@import.type.underscore.split('_').first}_sample.csv",
      type: "text/csv",
      disposition: "attachment"
  end

  def update
    if csv_valid?(csv_str)
      @import.account = import_account_id.present? ? accessible_accounts.find(import_account_id) : nil
      @import.assign_attributes(raw_file_str: csv_str, col_sep: upload_params[:col_sep])
      @import.save!(validate: false)

      redirect_to import_configuration_path(@import, template_hint: true), notice: t("imports.create.csv_uploaded")
    else
      flash.now[:alert] = t("import.uploads.show.csv_invalid", default: "Must be valid CSV with headers and at least one row of data")

      render :show, status: :unprocessable_entity
    end
  end

  private

    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def csv_str
      @csv_str ||= upload_params[:import_file]&.read || upload_params[:raw_file_str]
    end

    def csv_valid?(str)
      begin
        csv = Import.parse_csv_str(str, col_sep: upload_params[:col_sep])
        return false if csv.headers.empty?
        return false if csv.count == 0
        true
      rescue CSV::MalformedCSVError
        false
      end
    end

    def upload_params
      params.require(:import).permit(:raw_file_str, :import_file, :col_sep)
    end

    def import_account_id
      params.require(:import).permit(:account_id)[:account_id]
    end
end
