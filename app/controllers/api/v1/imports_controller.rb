# frozen_string_literal: true

class Api::V1::ImportsController < Api::V1::BaseController
  include Pagy::Backend

  # Ensure proper scope authorization
  before_action :ensure_read_scope, only: [ :index, :show, :rows, :preflight ]
  before_action :ensure_write_scope, only: [ :create ]
  before_action :reject_guest_family_config_import!, only: [ :create ]
  before_action :set_import_with_rows, only: [ :show ]
  before_action :set_import, only: [ :rows ]

  def index
    family = current_resource_owner.family
    imports_query = family.imports.where(type: Import::TYPES).ordered

    # Apply filters
    if params[:status].present?
      imports_query = imports_query.where(status: params[:status])
    end

    if params[:type].present?
      imports_query = imports_query.where(type: params[:type])
    end

    # Pagination
    @pagy, @imports = pagy(
      imports_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    @per_page = safe_per_page_param

    render :index

  rescue StandardError => e
    Rails.logger.error "ImportsController#index error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred." }, status: :internal_server_error
  end

  def show
    render :show
  rescue StandardError => e
    Rails.logger.error "ImportsController#show error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred." }, status: :internal_server_error
  end

  def rows
    @per_page = safe_per_page_param
    @pagy, @rows = pagy(
      @import.rows_ordered,
      page: safe_page_param,
      limit: @per_page
    )
    @rows.each(&:valid?)
    @row_mapping_lookup = @import.mappings.includes(:mappable).index_by { |mapping| [ mapping.type, mapping.key.to_s ] }

    render :rows
  rescue StandardError => e
    Rails.logger.error "ImportsController#rows error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred." }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family

    # 1. Determine type and validate
    type = params[:type].to_s
    type = "TransactionImport" unless Import::TYPES.include?(type)

    # 2. Build the import object with permitted config attributes
    @import = family.imports.build(import_config_params.merge(type: type))
    @import.account_id = params[:account_id] if params[:account_id].present?

    # 3. Attach the uploaded file if present (with validation)
    if params[:file].present?
      file = params[:file]

      if file.size > Import.max_csv_size
        return render json: {
          error: "file_too_large",
          message: "File is too large. Maximum size is #{Import.max_csv_size / 1.megabyte}MB."
        }, status: :unprocessable_entity
      end

      unless Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type)
        return render json: {
          error: "invalid_file_type",
          message: "Invalid file type. Please upload a CSV file."
        }, status: :unprocessable_entity
      end

      @import.raw_file_str = file.read
    elsif params[:raw_file_content].present?
      if params[:raw_file_content].bytesize > Import.max_csv_size
        return render json: {
          error: "content_too_large",
          message: "Content is too large. Maximum size is #{Import.max_csv_size / 1.megabyte}MB."
        }, status: :unprocessable_entity
      end

      @import.raw_file_str = params[:raw_file_content]
    end

    # 4. Save and Process
    if @import.save
      # Generate rows if file content was provided
      if @import.uploaded?
        begin
          @import.generate_rows_from_csv
          @import.reload
        rescue StandardError => e
          Rails.logger.error "Row generation failed for import #{@import.id}: #{e.message}"
        end
      end

      # If the import is configured (has rows), we can try to auto-publish or just leave it as pending
      # For API simplicity, if enough info is provided, we might want to trigger processing

      if @import.configured? && params[:publish] == "true"
        if current_resource_owner.guest? && @import.creates_categories_or_tags?
          return render_json({ error: "forbidden", message: "Guests cannot create categories or tags", import_id: @import.id }, status: :forbidden)
        end

        @import.publish_later
      end

      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Import could not be created",
        errors: @import.errors.full_messages
      }, status: :unprocessable_entity
    end

  rescue StandardError => e
    Rails.logger.error "ImportsController#create error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred." }, status: :internal_server_error
  end

  def preflight
    preflight_result = Import::Preflight.new(family: current_resource_owner.family, params: preflight_params).call
    render json: preflight_result.payload, status: preflight_result.status
  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "record_not_found",
      message: "The requested resource was not found"
    }, status: :not_found
  rescue CSV::MalformedCSVError => e
    render json: {
      error: "invalid_csv",
      message: "CSV content could not be parsed",
      errors: [ e.message ]
    }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "ImportsController#preflight error: #{e.message}"
    e.backtrace&.each { |line| Rails.logger.error line }

    render json: {
      error: "internal_server_error",
      message: "Import preflight could not be completed."
    }, status: :internal_server_error
  end

  private

    def reject_guest_family_config_import!
      return true unless Import::FAMILY_CONFIG_TYPES.include?(params[:type].to_s)

      reject_guest_writes!
    end

    def set_import
      @import = import_scope.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_import_not_found
    end

    def set_import_with_rows
      @import = import_scope.includes(:rows).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_import_not_found
    end

    def import_scope
      current_resource_owner.family.imports.where(type: Import::TYPES)
    end

    def render_import_not_found
      render json: { error: "not_found", message: "Import not found" }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def import_config_params
      params.permit(
        :date_col_label,
        :amount_col_label,
        :name_col_label,
        :category_col_label,
        :tags_col_label,
        :notes_col_label,
        :account_col_label,
        :qty_col_label,
        :ticker_col_label,
        :price_col_label,
        :entity_type_col_label,
        :currency_col_label,
        :exchange_operating_mic_col_label,
        :date_format,
        :number_format,
        :signage_convention,
        :col_sep,
        :amount_type_strategy,
        :amount_type_inflow_value,
        :rows_to_skip
      )
    end

    def preflight_params
      params.permit(*Import::Preflight::PARAM_KEYS)
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      (1..100).include?(per_page) ? per_page : 25
    end
end
