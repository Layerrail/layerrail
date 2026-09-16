# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "inference-endpoint" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", default_policy: nil) }

  describe "feature enabled" do
    before do
      allow(Config).to receive_messages(ai_inference_enabled: true, ai_inference_provider: "layerrail")
      login(user.email)
    end

    it "can handle empty list of inference endpoints" do
      visit "#{project.path}/inference-endpoint"

      expect(page.title).to eq("LayerRail - Inference Endpoints")
    end

    it "shows the right inference endpoints" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
      lb = LoadBalancer.create(private_subnet_id: ps.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: project.id)
      LoadBalancerPort.create(load_balancer_id: lb.id, src_port: 80, dst_port: 8000)
      [
        ["ie1", "e5-mistral-7b-it", project_wo_permissions, true, true, {capability: "Embeddings", hf_model: "foo/bar"}],
        ["ie2", "e5-mistral-8b-it", project_wo_permissions, true, false, {capability: "Embeddings"}],
        ["ie3", "llama-guard-3-8b", project_wo_permissions, false, true, {capability: "Text Generation"}],
        ["ie4", "mistral-small-3", project, false, true, {capability: "Text Generation"}],
        ["ie5", "llama-3-3-70b-turbo", project, false, true, {capability: "Text Generation"}],
        ["ie6", "test-model", project_wo_permissions, false, true, {capability: "Text Generation"}],
        ["ie7", "unknown-capability", project_wo_permissions, true, true, {capability: "wrong capability"}],
      ].each do |name, model_name, project, is_public, visible, tags|
        InferenceEndpoint.create(name:, model_name:, project_id: project.id, is_public:, visible:, load_balancer_id: lb.id, location_id: Location::HETZNER_FSN1_ID, vm_size: "size", replica_count: 1, boot_image: "image", storage_volumes: [], engine_params: "", engine: "vllm", private_subnet_id: ps.id, tags:)
      end

      visit "#{project.path}/inference-endpoint"

      expect(page.title).to eq("LayerRail - Inference Endpoints")
      expect(page).to have_content("e5-mistral-7b-it")
      expect(page.all("a").any? { |a| a["href"] == "https://huggingface.co/foo/bar" }).to be true
      expect(page).to have_no_content("e5-mistral-8b-it") # not visible
      expect(page).to have_no_content("llama-guard-3-8b") # private model of another project
      expect(page).to have_content("mistral-small-3")
      expect(page).to have_no_content("test-model") # no permissions
      expect(page).to have_no_content("unknown-capability")
    end

    it "shows the right inference router models" do
      private_subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
      load_balancer = LoadBalancer.create(
        private_subnet_id: private_subnet.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: project.id,
      )
      LoadBalancerPort.create(load_balancer_id: load_balancer.id, src_port: 80, dst_port: 8000)
      inference_router = InferenceRouter.create(
        name: "ir-name", location_id: Location::HETZNER_FSN1_ID, vm_size: "standard-2", replica_count: 1,
        project_id: project.id, load_balancer_id: load_balancer.id, private_subnet_id: private_subnet.id,
      )
      [
        ["meta-llama/Llama-3.2-1B-Instruct", "llama-3-2-1b-it-input", "llama-3-2-1b-it-output", true, {capability: "Text Generation", hf_model: "foo/bar"}],
        ["Invisible Model", "test-model-input", "test-model-output", false, {capability: "Text Generation"}],
        ["Unknown Capability", "test-model2-input", "test-model2-output", true, {capability: "Unknown"}],
      ].each do |model_name, prompt_billing, completion_billing, visible, tags|
        model = InferenceRouterModel.create(
          model_name:, prompt_billing_resource: prompt_billing, completion_billing_resource: completion_billing,
          project_inflight_limit: 100, project_prompt_tps_limit: 10_000, project_completion_tps_limit: 10_000,
          visible:, tags:,
        )
        InferenceRouterTarget.create(
          name: "test-target", host: "test-host", api_key: "test-key", inflight_limit: 10, priority: 1,
          inference_router_model_id: model.id, inference_router_id: inference_router.id, enabled: true,
        )
      end
      InferenceRouterModel.create(
        model_name: "Model without Target", prompt_billing_resource: "test-model2-input", completion_billing_resource: "test-model2-output",
        project_inflight_limit: 100, project_prompt_tps_limit: 10_000, project_completion_tps_limit: 10_000,
        visible: true, tags: {capability: "Text Generation"},
      )

      visit "#{project.path}/inference-endpoint"

      expect(page.title).to eq("LayerRail - Inference Endpoints")
      expect(page).to have_content("meta-llama/Llama-3.2-1B-Instruct")
      expect(page).to have_link(href: "https://huggingface.co/foo/bar")
      expect(page).to have_content("Input: $0.10 / 1M tokens")
      expect(page).to have_content("Output: $0.20 / 1M tokens")
      expect(page).to have_no_content("Invisible Model")
      expect(page).to have_no_content("Unknown Capability")
      expect(page).to have_no_content("Model without Target")
    end

    it "shows both inference endpoints and router models when both are present" do
      private_subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location::HETZNER_FSN1_ID).subject
      load_balancer = LoadBalancer.create(private_subnet_id: private_subnet.id, name: "dummy-lb-1", health_check_endpoint: "/up", project_id: project.id)
      LoadBalancerPort.create(load_balancer_id: load_balancer.id, src_port: 80, dst_port: 8000)
      InferenceEndpoint.create(
        name: "mistral-small-3",
        model_name: "mistral-small-3",
        project_id: project.id,
        is_public: true,
        visible: true,
        load_balancer_id: load_balancer.id,
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: "size",
        replica_count: 1,
        boot_image: "image",
        storage_volumes: [],
        engine_params: "",
        engine: "vllm",
        private_subnet_id: private_subnet.id,
        tags: {capability: "Text Generation"},
      )
      inference_router = InferenceRouter.create(
        name: "ir-name",
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: "standard-2",
        replica_count: 1,
        project_id: project.id,
        load_balancer_id: load_balancer.id,
        private_subnet_id: private_subnet.id,
      )
      inference_router_model = InferenceRouterModel.create(
        model_name: "meta-llama/Llama-3.2-1B-Instruct",
        prompt_billing_resource: "llama-3-2-1b-it-input",
        completion_billing_resource: "llama-3-2-1b-it-output",
        project_inflight_limit: 100,
        project_prompt_tps_limit: 1000,
        project_completion_tps_limit: 1000,
        visible: true,
        tags: {capability: "Text Generation"},
      )
      InferenceRouterTarget.create(
        name: "test-target",
        host: "test-host",
        api_key: "test-key",
        inflight_limit: 10,
        priority: 1,
        inference_router_model_id: inference_router_model.id,
        inference_router_id: inference_router.id,
        enabled: true,
      )
      visit "#{project.path}/inference-endpoint"
      expect(page.title).to eq("LayerRail - Inference Endpoints")
      expect(page).to have_content("mistral-small-3")
      expect(page).to have_content("meta-llama/Llama-3.2-1B-Instruct")
    end

    describe "Cloudflare catalog pricing" do
      let(:capability) { "Text Generation" }
      let(:input_price) { 0.0000000297 }
      let(:output_price) { 0.000000003421 }
      let(:cached_input_price) { nil }
      let(:catalog_prices) { [] }

      before do
        allow(Config).to receive(:ai_inference_provider).and_return("cloudflare")
        model_config = {
          "id" => "catalog-price-test", "model_name" => "@cf/catalog-price-test", "provider" => "cloudflare",
          "prompt_billing_resource" => "catalog-test-input", "completion_billing_resource" => "catalog-test-output",
          "tags" => {"capability" => capability, "pricing" => {"input" => 1, "output" => 2}, "catalog_prices" => catalog_prices},
        }
        model_config["cached_prompt_billing_resource"] = "catalog-test-cached-input" unless cached_input_price.nil?
        stub_const("Option::AI_MODELS", [model_config])
        allow(BillingRate).to receive(:from_resource_properties).and_call_original
        {"input" => input_price, "output" => output_price, "cached-input" => cached_input_price}.each do |kind, unit_price|
          rate = unit_price.nil? ? nil : {"unit_price" => unit_price}
          allow(BillingRate).to receive(:from_resource_properties)
            .with("InferenceTokens", "catalog-test-#{kind}", "global", any_args).and_return(rate)
        end
      end

      it "preserves small paid input and output rates" do
        visit "#{project.path}/inference-endpoint"

        expect(page).to have_content("Input: $0.0297 / 1M tokens")
        expect(page).to have_content("Output: $0.003421 / 1M tokens")
        expect(page).to have_no_content("Pricing unavailable")
        expect(page).to have_no_content("$0.00 / 1M tokens")
        expect(page).to have_no_content("Cached input:")
      end

      context "with cached input pricing" do
        let(:cached_input_price) { 0.000000011 }

        it "shows the configured cached input rate in the catalog and playground" do
          visit "#{project.path}/inference-endpoint"

          expect(page).to have_content("Cached input: $0.011 / 1M tokens")

          visit "#{project.path}/inference-playground"

          expect(page).to have_css('option[value="@cf/catalog-price-test"][data-cached-input-price="0.011"]', visible: :all)
        end
      end

      context "with a zero rate" do
        let(:output_price) { 0 }
        let(:cached_input_price) { 0.000000011 }

        it "marks the model unavailable instead of advertising free output" do
          visit "#{project.path}/inference-endpoint"

          expect(page).to have_content("Pricing unavailable")
          expect(page).to have_no_content("/ 1M tokens")
        end
      end

      context "with missing billing rates" do
        let(:input_price) { nil }
        let(:output_price) { nil }

        it "marks the model unavailable even when display-only prices exist" do
          visit "#{project.path}/inference-endpoint"

          expect(page).to have_content("Pricing unavailable")
          expect(page).to have_no_content("/ 1M tokens")
        end
      end

      context "with input-billed embeddings" do
        let(:capability) { "Embeddings" }
        let(:input_price) { 0.00000125 }
        let(:output_price) { nil }

        it "shows only the paid input rate" do
          visit "#{project.path}/inference-endpoint"

          expect(page).to have_content("Input: $1.25 / 1M tokens")
          expect(page).to have_no_content("Output:")
          expect(page).to have_no_content("Pricing unavailable")
        end
      end

      context "with catalog quotes for an unavailable model" do
        let(:output_price) { 0 }
        let(:catalog_prices) do
          [
            {"label" => "Input <=512k (per 1M)", "price" => "0.3300"},
            {"label" => "Output <=512k (per 1M)", "price" => "1.32"},
            {"label" => "Input >512k (per 1M)", "price" => "1.3200"},
            {"label" => "Image (per image)", "price" => "0.00000001"},
            {"label" => "Audio (per minute)", "price" => nil},
            {"label" => "Legacy input (per 1M)", "price" => "0"},
          ]
        end

        it "shows precise prices and their units while keeping the model unavailable" do
          visit "#{project.path}/inference-endpoint"

          expect(page).to have_content("Unavailable")
          expect(page).to have_button("Unavailable", disabled: true)
          expect(page).to have_no_link("Try in Playground")
          expect(page).to have_css("details summary", text: "View all 6 prices")
          within('dl[aria-label="Catalog prices"]', visible: :all) do
            expect(page).to have_css("dt", text: "Input <=512k (per 1M)", visible: :all)
            expect(page).to have_css("dd", exact_text: "$0.33", visible: :all)
            expect(page).to have_css("dt", text: "Image (per image)", visible: :all)
            expect(page).to have_css("dd", exact_text: "$0.00000001", visible: :all)
            expect(page).to have_css("dd", exact_text: "Pricing unavailable", count: 2, visible: :all)
            expect(page).to have_no_css("dd", exact_text: "$0.00", visible: :all)
          end
        end
      end

      context "with catalog quotes for a billable model" do
        let(:catalog_prices) do
          [
            {"label" => "Input tokens (per 1M)", "price" => "1"},
            {"label" => "Output tokens (per 1M)", "price" => "2"},
            {"label" => "Priority input tokens (per 1M)", "price" => "0.0594"},
          ]
        end

        it "prefers active input and output rates and shows only additional catalog prices" do
          visit "#{project.path}/inference-endpoint"

          expect(page).to have_content("Input: $0.0297 / 1M tokens")
          expect(page).to have_content("Output: $0.003421 / 1M tokens")
          within('dl[aria-label="Catalog prices"]') do
            expect(page).to have_css("dt", exact_text: "Priority input tokens (per 1M)", count: 1)
            expect(page).to have_css("dd", exact_text: "$0.0594", count: 1)
            expect(page).to have_no_css("dd", exact_text: "$1.00")
          end
          expect(page).to have_no_content("Unavailable")
        end
      end
    end

    %w[layerrail cloudflare].each do |provider|
      it "does not show #{provider} inference endpoints without project permissions" do
        allow(Config).to receive(:ai_inference_provider).and_return(provider)
        visit "#{project_wo_permissions.path}/inference-endpoint"

        expect(page.title).to eq("LayerRail - Forbidden")
        expect(page).to have_no_content("AI inference is paid from the first token")
      end
    end

    it "shows paid usage information instead of a free token allowance" do
      visit "#{project.path}/inference-api-key"
      expect(page.text).to include("AI inference is paid from the first token and billed on separate usage invoices.")
      expect(page).to have_no_css("[data-free-quota-value]")
      expect(page.text).not_to include("Free quota")
    end

    it "shows connected billing when a non-fraudulent payment method exists" do
      allow(BachsClient).to receive(:enabled?).and_return(true)
      billing_info = BillingInfo.create(stripe_id: "bachs:#{project.ubid}")
      project.update(billing_info_id: billing_info.id)
      PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "bachs:payment-#{project.ubid}")
      visit "#{project.path}/inference-api-key"
      expect(page.text).to include("Billing is connected. Pay usage invoices to keep inference available.")
    end

    it "asks for a payment method before allowing paid inference" do
      visit "#{project.path}/inference-api-key"
      expect(page.text).to include("Before using inference, click here to add a valid billing method.")
    end
  end

  describe "unauthenticated" do
    it "inference endpoint page is not accessible" do
      visit "/inference-endpoint"

      expect(page.title).to eq("LayerRail - Login")
    end
  end
end
