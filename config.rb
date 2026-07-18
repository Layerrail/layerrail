# frozen_string_literal: true

require_relative "lib/casting_config_helpers"

begin
  require_relative ".env"
rescue LoadError
  # .env.rb is optional
  nil
end

# :nocov:
$stdout.sync = $stderr.sync = true if ENV["SYNC"] == "1"
# :nocov:

# Adapted from
# https://github.com/interagent/pliny/blob/fcc8f3b103ec5296bd754898fdefeb2fda2ab292/lib/template/config/config.rb.
#
# It is MIT licensed.

# Access all config keys like the following:
#
#     Config.database_url
#
# Each accessor corresponds directly to an ENV key, which has the same name
# except upcased, i.e. `DATABASE_URL`.
module Config
  extend CastingConfigHelpers

  def self.production?
    rack_env == "production"
  end

  def self.development?
    rack_env == "development"
  end

  def self.test?
    rack_env == "test"
  end

  def self.frozen_test?
    test? && clover_freeze?
  end

  def self.unfrozen_test?
    test? && !clover_freeze?
  end

  mandatory :clover_database_url, string, clear: true
  mandatory :clover_column_encryption_key, base64, clear: true
  mandatory :clover_session_secret, base64, clear: true
  mandatory :rack_env, string

  override :clover_admin_development_no_webauthn, false, bool
  override :clover_admin_links_to_clover, false, bool
  optional :clover_runtime_token_secret, base64, clear: true
  optional :kms_decrypt_clover_column_encryption_key_with_arn, string
  optional :heartbeat_url, string
  optional :clover_database_root_certs, string
  override :max_health_monitor_threads, 32, int
  override :max_metrics_export_threads, 32, int
  optional :omniauth_github_id, string, clear: true
  optional :omniauth_github_secret, string, clear: true
  optional :omniauth_google_id, string, clear: true
  optional :omniauth_google_secret, string, clear: true
  optional :hetzner_ssh_private_key, string, clear: true
  optional :hetzner_ssh_private_key_passphrase, string, clear: true
  optional :operator_ssh_public_keys, string
  override :staging, false, bool
  override :clover_freeze, false, bool
  optional :override_dir, string

  optional :resend_api_key, string, clear: true
  optional :resend_from_email, string
  optional :resend_webhook_secret, string, clear: true
  # :nocov:
  override :mail_driver, (resend_api_key ? :resend : (production? ? :smtp : :logger)), symbol
  override :mail_from, (resend_from_email || (production? ? nil : "dev@example.com")), string
  override :account_verification_enabled, (!development? || mail_driver == :resend), bool
  # :nocov:
  # Some email services use a secret token for both user and password,
  # so clear them both.
  optional :smtp_user, string, clear: true
  optional :smtp_password, string, clear: true
  optional :smtp_hostname, string
  override :smtp_port, 587, int
  override :smtp_tls, true, bool

  override :base_url, "http://localhost:9292", string
  override :admin_url, "http://admin.localhost:9292", string
  optional :api_url, string
  override :database_timeout, 10, int
  override :database_timeout_web, Config.database_timeout, int
  override :database_timeout_respirate, Config.database_timeout, int
  override :database_timeout_monitor, Config.database_timeout, int
  override :db_pool, 5, int
  override :db_pool_web, Config.db_pool, int
  override :db_pool_respirate, Config.db_pool, int
  override :db_pool_monitor, Config.db_pool, int
  override :dispatcher_max_threads, 8, int
  override :dispatcher_min_threads, 1, int
  override :dispatcher_queue_size_ratio, 4, float
  override :recursive_tag_limit, 32, int
  override :root, File.expand_path(__dir__), string
  override :aws_role_session_name, "ubi", string
  # :nocov:
  override :provider_resource_tag_value, (development? ? ENV.fetch("USER", "true") : "true"), string
  # :nocov:
  override :clover_database_rds_iam_auth_enabled, false, bool
  optional :linode_access_token, string, clear: true
  override :linode_api_base_url, "https://api.linode.com/v4", string
  optional :azure_subscription_id, string, clear: true
  optional :azure_tenant_id, string, clear: true
  optional :azure_client_id, string, clear: true
  optional :azure_client_secret, string, clear: true
  override :azure_arm_base_url, "https://management.azure.com", string
  override :compute_provider, "azure", string
  override :game_vps_enabled, false, bool
  override :game_vps_provider, "azure", string
  optional :ionos_api_token, string, clear: true
  optional :ionos_username, string, clear: true
  optional :ionos_password, string, clear: true
  override :ionos_api_base_url, "https://api.ionos.com/cloudapi/v6", string
  override :ionos_game_vps_cpu_family, "INTEL_ICELAKE", string
  override :ionos_game_vps_disk_type, "SSD", string
  override :ionos_windows_image_alias, "windows:2022", string
  optional :hetzner_user, string, clear: true
  optional :hetzner_password, string, clear: true
  override :hetzner_connection_string, "https://robot-ws.your-server.de", string
  override :managed_service, false, bool
  override :sanctioned_countries, "CU,IR,KP,SY", array(string)
  override :hetzner_ssh_public_key, nil, string
  override :minimum_invoice_charge_threshold, 0.5, float
  optional :cloudflare_turnstile_site_key, string
  optional :cloudflare_turnstile_secret_key, string
  override :allow_unspread_servers, !production?, bool
  override :control_plane_outbound_cidrs, "0.0.0.0/0,::/0", array(string)
  optional :git_commit_hash, string
  optional :ip_from_header, string

  # GitHub Runner App
  optional :github_app_name, string
  optional :github_app_id, string
  optional :github_app_client_id, string, clear: true
  optional :github_app_client_secret, string, clear: true
  optional :github_app_private_key, string, clear: true
  optional :github_app_webhook_secret, string, clear: true
  optional :vm_pool_project_id, uuid
  optional :github_runner_service_project_id, uuid
  optional :github_runner_linode_location_id, uuid
  override :github_runner_bootstrap_version, "latest", string
  override :enable_github_workflow_poller, true, bool
  optional :github_runner_aws_location_id, uuid
  override :github_runner_aws_spot_instance_enabled, false, bool
  optional :github_runner_aws_spot_instance_max_price_per_vcpu, float
  override :github_runner_aws_spill_threshold_seconds, 30, int
  override :github_runner_aws_spill_vcpu_capacity, 100, int

  # GitHub Cache
  optional :github_cache_blob_storage_endpoint, string
  optional :github_cache_blob_storage_region, string
  optional :github_cache_blob_storage_access_key, string, clear: true
  optional :github_cache_blob_storage_secret_key, string, clear: true
  optional :github_cache_blob_storage_account_id, string
  optional :github_cache_blob_storage_api_key, string, clear: true
  override :github_cache_blob_storage_use_account_token, false, bool

  # Minio
  override :minio_host_name, "minio.layerrail.com", string
  override :object_storage_public_domain, "layerrail.com", string
  override :object_storage_worker_name, "layerrail-s3-gateway", string
  optional :minio_service_project_id, uuid
  override :minio_version, "minio_20250723155402.0.0_amd64", string

  # Edge
  override :edge_service_hostname, "edge.layerrail.com", string
  override :edge_proxy_hostname, "layerrail-web.onrender.com", string
  override :edge_worker_name, "layerrail-edge-proxy", string

  # Parseable
  optional :parseable_service_project_id, uuid
  override :parseable_host_name, "logs.layerrail.com", string
  override :parseable_version, "v2.6.5", string
  optional :parseable_endpoint_override, string

  # VictoriaMetrics
  optional :victoria_metrics_service_project_id, uuid
  override :victoria_metrics_host_name, "metrics.layerrail.com", string
  override :victoria_metrics_version, "v1.113.0", string
  optional :victoria_metrics_endpoint_override, string

  # Spdk
  override :spdk_version, "v23.09-ubi-0.3", string

  # Vhost Block Backend
  override :vhost_block_backend_version, "v0.2.2", string

  # Boot Images
  override :default_boot_image_name, "ubuntu-jammy", string

  # Machine Images
  override :machine_image_max_size_gib, 40, int
  optional :machine_images_service_project_id, uuid

  # Pagerduty
  optional :pagerduty_key, string, clear: true
  optional :pagerduty_log_link, string

  # incident.io
  optional :incidentio_key, string, clear: true
  optional :incidentio_alert_source_config_id, string

  # Postgres
  override :postgres_enabled, true, bool
  optional :postgres_service_project_id, uuid
  override :postgres_service_hostname, "postgres.layerrail.com", string
  override :postgres_monitor_database_url, Config.clover_database_url, string
  optional :postgres_monitor_database_root_certs, string
  optional :postgres_paradedb_notification_email, string
  optional :postgres_lantern_notification_email, string
  optional :postgres_notification_email, string
  override :aws_postgres_iam_access, false, bool
  override :postgres_internal_firewall_cidrs, "", array(string)

  # Logging
  optional :database_logger_level, string
  optional :ingest_key, string, clear: true
  optional :otel_exporter_otlp_endpoint, string
  override :pry_logger_truncate_limit, 500, int

  # LayerRail Images (Minio)
  override :ubicloud_images_bucket_name, "layerrail-images", string
  optional :ubicloud_images_blob_storage_endpoint, string
  optional :ubicloud_images_blob_storage_access_key, string, clear: true
  optional :ubicloud_images_blob_storage_secret_key, string, clear: true
  optional :ubicloud_images_blob_storage_certs, string

  # LayerRail Images (R2)
  optional :ubicloud_images_r2_bucket_name, string
  optional :ubicloud_images_r2_endpoint, string
  optional :ubicloud_images_r2_access_key, string, clear: true
  optional :ubicloud_images_r2_secret_key, string, clear: true

  override :github_ubuntu_2204_x64_aws_ami_version, "ami-03a534f7fa3ae9887", string
  override :github_ubuntu_2404_x64_aws_ami_version, "ami-092dab75acd086240", string
  override :github_ubuntu_2204_arm64_aws_ami_version, "ami-02d3ba0a683f05899", string
  override :github_ubuntu_2404_arm64_aws_ami_version, "ami-08b8e7b576e356f54", string
  override :postgres_gce_image_gcp_project_id, "layerrail-images", string

  # Allocator
  override :allocator_target_host_utilization, 0.72, float
  override :allocator_target_premium_host_utilization, 0.85, float
  override :allocator_max_random_score, 0.1, float

  # e2e
  override :e2e_hetzner_server_id, nil, string
  optional :e2e_github_installation_id, string
  override :is_e2e, false, bool
  optional :e2e_aws_access_key, string, clear: true
  optional :e2e_aws_secret_key, string, clear: true
  optional :e2e_aws_assume_role, string
  optional :e2e_gcp_credentials_base64_json, string, clear: true
  optional :e2e_cache_proxy_download_url, string

  # Local e2e
  optional :local_e2e_postgres_test_project_id, uuid

  # Rollouts
  optional :rollouts_project_id, uuid

  # Load Balancer
  optional :load_balancer_service_project_id, uuid
  override :load_balancer_service_hostname, "lb.layerrail.com", string

  # ACME
  override :acme_email, "support@layerrail.com", string
  override :acme_directory, "https://acme-v02.api.letsencrypt.org/directory", string
  optional :acme_eab_kid, string, clear: true
  optional :acme_eab_hmac_key, string, clear: true

  # AI
  override :ai_inference_enabled, false, bool
  override :ai_inference_provider, "cloudflare", string
  optional :cloudflare_account_id, string
  optional :cloudflare_api_token, string, clear: true
  optional :azure_foundry_endpoint, string
  optional :azure_foundry_api_key, string, clear: true
  override :azure_foundry_api_version, "2025-01-01-preview", string
  optional :inference_endpoint_service_project_id, uuid
  optional :runpod_api_key, string, clear: true
  optional :huggingface_token, string, clear: true
  override :inference_dns_zone, "ai.layerrail.com", string
  optional :inference_router_access_token, string, clear: true
  override :inference_router_release_tag, "v0.1.8", string
  override :premium_ai_metering_enabled, true, bool
  override :premium_ai_trial_enabled, true, bool
  override :premium_ai_trial_days, 30, int
  override :premium_ai_polar_event_name, "layerrail_ai_usage", string
  override :premium_ai_charge_threshold_cents, 500, int
  override :premium_ai_monthly_spend_cap_cents, 1000, int
  override :premium_ai_rate_limit_fallback_enabled, true, bool

  # DNS
  optional :dns_service_project_id, uuid
  optional :cloudflare_dns_api_token, string, clear: true
  optional :cloudflare_dns_zone_id, string, clear: true
  override :cloudflare_dns_proxied, false, bool

  # Domains
  override :domains_enabled, false, bool
  override :domains_provider, "namesilo", string
  optional :namesilo_api_key, string, clear: true
  override :namesilo_api_base_url, "https://www.namesilo.com/api", string
  optional :polar_domain_product_id, uuid
  override :domain_registration_markup_percent, 0.0, float
  override :domain_registration_discount_percent, 0.0, float

  # Kubernetes
  override :kubernetes_enabled, true, bool
  optional :kubernetes_service_project_id, uuid
  override :kubernetes_service_hostname, "k8s.layerrail.com", string

  # Deploy
  override :deploy_enabled, true, bool
  optional :deploy_service_project_id, uuid
  override :deploy_service_hostname, "apps.layerrail.com", string
  override :deploy_default_vm_size, "nanode-4", string
  override :deploy_default_port, 3000, int
  override :deploy_infrastructure_controls_enabled, false, bool
  override :deploy_container_registry_host, "layerrailregistry.azurecr.io", string
  override :deploy_container_registry_repository, "layerrail-deploy", string
  optional :deploy_container_registry_username, string, clear: true
  optional :deploy_container_registry_password, string, clear: true

  # Billing
  optional :polar_access_token, string, clear: true
  optional :polar_webhook_secret, string, clear: true
  override :polar_api_base_url, "https://api.polar.sh/v1", string
  optional :polar_organization_id, uuid
  optional :polar_verification_product_id, uuid
  optional :polar_checkout_product_id, uuid
  optional :polar_invoice_product_id, uuid
  optional :polar_game_vps_product_id, uuid
  optional :polar_game_vps_product_ids, string, clear: true
  optional :bachs_api_key, string, clear: true
  optional :bachs_webhook_secret, string, clear: true
  override :bachs_api_base_url, "https://api.bachs.io", string
  optional :bachs_verification_product_id, string, clear: true
  override :bachs_verification_amount_cents, 100, int
  optional :bachs_game_vps_product_ids, string, clear: true
  override :game_vps_checkout_provider, "bachs", string
  override :billing_checkout_provider, "bachs", string
  optional :invoice_eu_bank_iban, string, clear: true
  optional :stripe_secret_key, string, clear: true
  override :annual_non_dutch_eu_sales_exceed_threshold, false, bool
  optional :invalid_vat_notification_email, string
  override :invoices_bucket_name, "layerrail-invoices", string
  optional :invoices_blob_storage_endpoint, string
  optional :invoices_blob_storage_access_key, string, clear: true
  optional :invoices_blob_storage_secret_key, string, clear: true

  # Monitoring
  optional :monitoring_service_project_id, uuid

  # Intercom
  override :intercom_messenger_enabled, true, bool
  override :intercom_app_id, "fhtipjhd", string
  override :intercom_api_base, "https://api-iam.intercom.io", string
  optional :intercom_identity_verification_secret, string, clear: true
end
