import { visibleAnswer, readEventStream } from "./response.js";

export function setupPlayground(effects = { orb() {}, busy() {} }) {
  if ($('#inference_submit').length === 0) {
    return;
  }

  const previous_messages = [];
  const previous_message_containers = [];
  const session_usage = { prompt_tokens: 0, completion_tokens: 0, cost: 0 };
  const playground = document.getElementById('inference_playground');
  const conversation = document.getElementById('inference_conversation');
  const welcomeOrb = document.getElementById('inference_welcome_orb');
  let activeRequest = null;
  effects.orb(welcomeOrb, 'breathing');

  function announce(text) { $('#inference_status').text(text); }

  function showError(text) {
    $('#inference_error').text(text).prop('hidden', false);
  }

  function setActivity(state, request) {
    if (request && activeRequest !== request) return;
    const busy = ['waiting', 'reasoning', 'streaming'].includes(state);
    const changed = playground.dataset.state !== state;
    playground.dataset.state = state;
    $('#inference_previous').attr('aria-busy', busy);
    $('#inference_submit_label').text(busy ? 'Stop' : 'Send');
    $('#inference_submit_icon').text(busy ? '■' : '↑');
    $('#inference_submit').attr('aria-label', busy ? 'Stop response' : 'Send message');
    $('#inference_endpoint, #inference_api_key, #inference_config_advanced_settings').prop('disabled', busy);
    $('[data-prompt-template]').prop('disabled', busy);
    effects.busy(busy);
    update_file_input_state();
    if (request?.orb) effects.orb(request.orb, { waiting: 'working', reasoning: 'solving', streaming: 'composing' }[state]);
    if (changed && busy) announce({ waiting: 'Waiting for the model.', reasoning: 'The model is reasoning.', streaming: 'The model is responding.' }[state]);
  }

  function scrollConversation(force = false) {
    if (force || conversation.scrollHeight - conversation.scrollTop - conversation.clientHeight < 100) {
      requestAnimationFrame(() => { conversation.scrollTop = conversation.scrollHeight; });
    }
  }

  function resizePrompt() {
    const prompt = document.getElementById('inference_prompt');
    prompt.style.height = 'auto';
    prompt.style.height = Math.min(prompt.scrollHeight, 220) + 'px';
  }

  function updateAttachments() {
    const files = Array.from(document.getElementById('inference_files').files || []);
    const mode = selectedEndpointFileMode();
    const summary = files.length ? files.map((file) => file.name).join(', ') :
      mode === 'none' ? 'Text only' : mode === 'audio' ? 'Attach audio' : mode === 'chat-multimodal' ? 'Images & PDFs' : 'Attach an image';
    $('#inference_attachment_summary').text(summary).attr('title', summary);
    $('#inference_clear_files').prop('hidden', files.length === 0).prop('disabled', !!activeRequest);
  }
  let remaining_free_quota = Number($('[data-free-quota-value]').first().attr('data-free-quota-value') || 0);

  const prompt_templates = {
    summarize: {
      system: "You summarize technical content clearly and preserve the important details.",
      prompt: "Summarize the following content in concise bullet points:\n\n"
    },
    classify: {
      system: "You classify incoming requests into a compact JSON object.",
      prompt: "Classify this request by intent, urgency, and required product area:\n\n"
    },
    json: {
      system: "Return only valid JSON. Do not include markdown or commentary.",
      prompt: "Return a JSON object for the following request:\n\n"
    },
    code: {
      system: "You explain code with attention to behavior, edge cases, and production risk.",
      prompt: "Explain what this code does and call out any important risks:\n\n"
    }
  };

  function selectedEndpointOption() {
    return $('#inference_endpoint option:selected');
  }

  function selectedEndpointNumber(name) {
    const value = parseFloat(selectedEndpointOption().attr(name));
    return Number.isFinite(value) ? value : 0;
  }

  function selectedCapability() {
    return selectedEndpointOption().attr('data-capability') || "Text Generation";
  }

  function selectedEndpointApi() {
    return selectedEndpointOption().attr('data-api') || "chat";
  }

  function selectedTags() {
    try {
      return JSON.parse(selectedEndpointOption().attr('data-tags') || '{}');
    } catch (_) {
      return {};
    }
  }

  function selectedEndpointUsesNativeRun() {
    return [
      "Automatic Speech Recognition",
      "Image Classification",
      "Image Text to Text",
      "Image-to-Text",
      "Object Detection",
      "Rerank",
      "Summarization",
      "Text Classification",
      "Text-to-Image",
      "Text-to-Speech",
      "Translation",
      "Voice Activity Detection",
    ].includes(selectedCapability());
  }

  function selectedEndpointFileMode() {
    const capability = selectedCapability();
    if (["Automatic Speech Recognition", "Voice Activity Detection"].includes(capability)) return "audio";
    if (["Image Classification", "Object Detection", "Image-to-Text"].includes(capability)) return "image-bytes";
    if (capability === "Image Text to Text") return "image-base64";
    if (selectedTags()['multimodal']) return "chat-multimodal";
    return "none";
  }

  function taskHintForCapability(capability) {
    return {
      "Text Generation": "Ask, explore, and build on the conversation.",
      "Embeddings": "Turn text into vectors for search and similarity.",
      "Text-to-Image": "Generate an image from a prompt. Advanced settings can set width and height.",
      "Text-to-Speech": "Generate speech audio from text. Set language in advanced settings when needed.",
      "Automatic Speech Recognition": "Upload an audio file to transcribe it.",
      "Voice Activity Detection": "Upload an audio file to find speech segments.",
      "Translation": "Translate the prompt text. Set source and target language in advanced settings.",
      "Summarization": "Summarize long text. Max output tokens controls summary length.",
      "Rerank": "Use the prompt as the query and add one document per line in extra context.",
      "Text Classification": "Classify the prompt text and return labels with confidence scores.",
      "Image Classification": "Upload an image and classify what it contains.",
      "Object Detection": "Upload an image and detect objects with bounding boxes.",
      "Image-to-Text": "Upload an image and ask for a description.",
      "Image Text to Text": "Upload an image and ask a question about it.",
    }[capability] || "Explore what this model can do.";
  }

  function formatTokenCount(value) {
    return Number(value || 0).toLocaleString();
  }

  function formatPrice(value) {
    const number = Number(value || 0);
    return `$${number.toFixed(2)}`;
  }

  function formatEstimatedCost(value) {
    const number = Number(value || 0);
    if (number > 0 && number < 0.000001) {
      return "less than $0.000001";
    }
    return `$${number.toFixed(6)}`;
  }

  function estimateCost(prompt_tokens, completion_tokens, input_price = selectedEndpointNumber('data-input-price'), output_price = selectedEndpointNumber('data-output-price')) {
    return (prompt_tokens * input_price + completion_tokens * output_price) / 1_000_000;
  }

  function estimateTokenCount(value) {
    const text = typeof value === "string" ? value : JSON.stringify(value || "");
    return Math.max(Math.ceil(text.length / 4), 1);
  }

  function updateMessageCount() {
    const count = previous_messages.length;
    $('#inference_session_message_count').text(`${count} message${count === 1 ? "" : "s"}`);
  }

  function updateUsagePanel() {
    $('#inference_session_usage').text(`${formatTokenCount(session_usage.prompt_tokens)} input · ${formatTokenCount(session_usage.completion_tokens)} output`);
    $('#inference_session_cost').text(formatEstimatedCost(session_usage.cost));
  }

  function updateFreeQuotaDisplay() {
    $('[data-free-quota-value]').each(function () {
      $(this).attr('data-free-quota-value', remaining_free_quota);
      $(this).text(formatTokenCount(remaining_free_quota));
    });
  }

  function recordUsage(prompt_tokens, completion_tokens, message_id, input_price, output_price, uses_free_quota = true) {
    prompt_tokens = Number(prompt_tokens || 0);
    completion_tokens = Number(completion_tokens || 0);
    const cost = estimateCost(prompt_tokens, completion_tokens, input_price, output_price);
    const total_tokens = prompt_tokens + completion_tokens;
    const summary = `Usage: ${formatTokenCount(prompt_tokens)} input tokens and ${formatTokenCount(completion_tokens)} output tokens. Estimated cost: ${formatEstimatedCost(cost)}.`;

    $(`#inference_message_info_${message_id}`).text(summary);
    $('#inference_last_usage').text(`${formatTokenCount(prompt_tokens)} input tokens and ${formatTokenCount(completion_tokens)} output tokens`);

    session_usage.prompt_tokens += prompt_tokens;
    session_usage.completion_tokens += completion_tokens;
    session_usage.cost += cost;
    if (uses_free_quota) {
      remaining_free_quota = Math.max(remaining_free_quota - total_tokens, 0);
    }
    updateUsagePanel();
    updateFreeQuotaDisplay();
  }

  function updateSelectedModelDetails() {
    const $option = selectedEndpointOption();
    if ($option.length === 0 || !$option.val()) {
      $('#inference_selected_model_name').text("No model selected");
      $('#inference_selected_provider').text("-");
      $('#inference_selected_capability').text("-");
      $('#inference_selected_context').text("-");
      $('#inference_selected_price').text("-");
      $('#inference_selected_url').text("-");
      return;
    }

    const input_price = selectedEndpointNumber('data-input-price');
    const output_price = selectedEndpointNumber('data-output-price');
    $('#inference_selected_model_name').text($option.attr('data-display-name') || $option.val());
    $('#inference_selected_provider').text($option.attr('data-provider-label') || $option.attr('data-provider') || "LayerRail");
    $('#inference_selected_capability').text($option.attr('data-capability') || "-");
    $('#inference_selected_context').text($option.attr('data-context-length') || "-");
    $('#inference_selected_price').text(`${formatPrice(input_price)} input / ${formatPrice(output_price)} output per 1M tokens`);
    $('#inference_selected_url').text($option.attr('data-url') || "-");
  }

  function applyPromptTemplate() {
    const selected = $('#inference_prompt_template').val();
    const template = prompt_templates[selected];
    if (!template) {
      return;
    }

    $('#inference_system').val(template.system);
    $('#inference_prompt').val(template.prompt).trigger('focus');
    $('#inference_response_format').val(selected === "json" ? "json_object" : "");
    resizePrompt();
  }

  // Initialize the model selector based on the location hash.
  const hash = window.location.hash.slice(1);
  if (hash !== '') {
    const $select = $('#inference_endpoint');
    const $option = $select.find('option').filter(function () {
      return $(this).data('id') === hash;
    });
    if ($option.length > 0) {
      $select.val($option.val()).trigger('change');
    }
  }

  // Disable the file input if the selected model is not multimodal.
  function update_file_input_state() {
    const mode = selectedEndpointFileMode();
    const $files = $('#inference_files');
    $files.prop('disabled', mode === "none" || !!activeRequest);
    $('#inference_attach').prop('disabled', $files.prop('disabled'));
    $files.prop('multiple', mode === 'chat-multimodal');
    if (mode === "audio") {
      $files.attr('accept', ".wav,.mp3,.m4a,.ogg,.webm");
    } else if (mode === 'chat-multimodal') {
      $files.attr('accept', '.jpg,.jpeg,.png,.webp,.pdf');
    } else if (["image-bytes", "image-base64"].includes(mode)) {
      $files.attr('accept', ".jpg,.jpeg,.png,.webp");
    } else {
      $files.attr('accept', "");
    }
    updateAttachments();
  }

  function syncSelectedEndpoint() {
    const capability = selectedCapability();
    update_file_input_state();
    updateSelectedModelDetails();
    updateUsagePanel();
    $('#inference_task_hint').text(taskHintForCapability(capability));
    $('#inference_context_container').toggleClass("hidden", capability !== "Rerank");
    $('#inference_starters').prop('hidden', capability !== 'Text Generation');
    const promptLabel = capability === "Embeddings" ? "Input text" :
      capability === "Rerank" ? "Query" :
      ["Image Classification", "Object Detection", "Automatic Speech Recognition", "Voice Activity Detection"].includes(capability) ? "Optional prompt" :
      "Message";
    $('label[for="inference_prompt"]').text(promptLabel);
    $('#inference_prompt').attr('placeholder', capability === 'Text Generation' ? 'Ask anything, or try an idea…' : taskHintForCapability(capability));
  }

  syncSelectedEndpoint();
  $('#inference_endpoint').on('change', () => {
    $('#inference_files').val('');
    syncSelectedEndpoint();
  });

  $("#inference_new_chat").click(() => {
    if (activeRequest) {
      activeRequest.controller.abort();
      effects.orb(activeRequest.orb, null);
      activeRequest = null;
    }
    for (const container of previous_message_containers) {
      container.remove();
    }
    previous_messages.splice(0);
    previous_message_containers.splice(0);
    $("#inference_previous_empty").show();
    effects.orb(welcomeOrb, 'breathing');
    $('#inference_prompt, #inference_files, #inference_context').val('');
    $('#inference_error').prop('hidden', true);
    session_usage.prompt_tokens = 0;
    session_usage.completion_tokens = 0;
    session_usage.cost = 0;
    $('#inference_last_usage').text("No usage yet");
    updateMessageCount();
    updateUsagePanel();
    setActivity('idle');
    resizePrompt();
    $('#inference_prompt').trigger('focus');
    announce('New conversation started.');
  });

  function readFileAsDataURL(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = reject;
      reader.readAsDataURL(file);
    });
  }

  function readFileAsBytes(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(Array.from(new Uint8Array(reader.result)));
      reader.onerror = reject;
      reader.readAsArrayBuffer(file);
    });
  }

  async function readFirstFile(input, mode) {
    const file = Array.from(input.files || [])[0];
    if (!file) {
      return null;
    }
    if (mode === "image-base64") {
      const dataUrl = await readFileAsDataURL(file);
      return dataUrl.split(",", 2)[1] || "";
    }
    return readFileAsBytes(file);
  }

  async function readFilesFromInput(input) {
    if (input.disabled) {
      return [];
    }
    const files = Array.from(input.files);
    const contents = [];
    for (const file of files) {
      const result = await readFileAsDataURL(file);
      const mimeType = file.type;
      if (mimeType.startsWith("image/")) {
        contents.push({
          type: "image_url",
          image_url: { url: result },
        });
      } else if (mimeType === "application/pdf") {
        contents.push({
          type: "file",
          file: { filename: file.name, file_data: result },
        });
      } else {
        throw new Error(`Unsupported file type ${mimeType} for file ${file.name}. Only images and PDFs are supported.`);
      }
    }
    return contents;
  }

  function appendMessage(message, show_processing = false) {
    const role = message.role;
    const text = message.content[0].text;
    const message_id = previous_messages.length;
    // The `clipboard-document` and `check` icons from https://heroicons.com.
    const COPY_ICON = '<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 0 1-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 0 1 1.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 0 0-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 0 1-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 0 0-3.375-3.375h-1.5a1.125 1.125 0 0 1-1.125-1.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H9.75"></path>';
    const CHECK_ICON = '<path stroke-linecap="round" stroke-linejoin="round" d="m4.5 12.75 6 6 9-13.5" />';
    const num_files = message.content.length - 1;
    const $new_message = $(`
      <article class="playground-message" data-role="${role}">
        <div class="playground-message-heading">
          <span class="playground-message-name"></span>
          <button type="button" id="copy_inference_message_${message_id}" class="playground-copy" aria-label="Copy ${role === 'user' ? 'message' : 'response'}" ${show_processing ? 'hidden' : ''}>
            <svg id="inference_icon_${message_id}" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" aria-hidden="true">
              ${COPY_ICON}
            </svg>
          </button>
        </div>
        <div id="inference_message_${message_id}" class="playground-message-body"></div>
        <div class="playground-message-files">${num_files > 0 ? `Attached ${num_files} file(s).` : ''}</div>
        <div id="inference_orb_${message_id}" class="playground-orb playground-response-orb" aria-hidden="true" ${show_processing ? '' : 'hidden'}></div>
        <div id="inference_message_info_${message_id}" class="playground-message-info"></div>
      </article>
    `);
    $new_message.find('.playground-message-name').text(role === 'user' ? 'You' : ($('#inference_selected_model_name').text() || 'Assistant'));
    $new_message.find('.playground-message-body').text(text);
    $("#inference_previous_empty").hide();
    effects.orb(welcomeOrb, null);
    $("#inference_previous").append($new_message);
    previous_message_containers.push($new_message);
    previous_messages.push(message);
    updateMessageCount();
    let timeout = undefined;
    $(`#copy_inference_message_${message_id}`).click(async () => {
      try {
        await window.navigator.clipboard.writeText(message.content[0].text);
      } catch (_) {
        showError('Could not copy to the clipboard. Select and copy the response instead.');
        return;
      }
      $(`#inference_icon_${message_id}`).html(CHECK_ICON);
      announce('Copied to clipboard.');
      clearTimeout(timeout);
      timeout = setTimeout(() => {
        $(`#inference_icon_${message_id}`).html(COPY_ICON);
      }, 1000);
    });
    scrollConversation(true);
    return document.getElementById(`inference_orb_${message_id}`);
  }

  function renderJson(value) {
    return `<pre>${$('<div>').text(JSON.stringify(value, null, 2)).html()}</pre>`;
  }

  function renderScoreList(items) {
    if (!Array.isArray(items)) {
      return renderJson(items);
    }
    const rows = items.map((item) => {
      const label = item?.label ?? item?.index ?? "result";
      const score = Number(item?.score);
      const scoreText = Number.isFinite(score) ? `${(score * 100).toFixed(2)}%` : "";
      const box = item?.box ? ` (${JSON.stringify(item.box)})` : "";
      return `<li><span class="font-medium">${DOMPurify.sanitize(String(label))}</span>${scoreText ? ` - ${scoreText}` : ""}${DOMPurify.sanitize(box)}</li>`;
    }).join("");
    return `<ul class="list-disc pl-5 text-sm">${rows}</ul>`;
  }

  function renderInferenceResult(parsed, capability) {
    const result = parsed?.result ?? parsed;
    if (capability === "Text Generation") {
      const text = extractTextGenerationResponse(parsed);
      return { text, html: DOMPurify.sanitize(marked.parse(text || JSON.stringify(result, null, 2))) };
    }
    if (capability === "Text-to-Image" && typeof result === "string") {
      const image = result.replace(/[^A-Za-z0-9+/=]/g, "");
      return {
        text: "[Generated image]",
        html: `<img alt="Generated image" class="max-w-full rounded-lg border border-gray-200" src="data:image/png;base64,${image}">`,
      };
    }
    if (capability === "Text-to-Speech") {
      const audio = typeof result === "string" ? result : result?.audio;
      const sanitizedAudio = audio ? audio.replace(/[^A-Za-z0-9+/=]/g, "") : "";
      return {
        text: "[Generated audio]",
        html: sanitizedAudio ? `<audio controls class="w-full" src="data:audio/mpeg;base64,${sanitizedAudio}"></audio>` : renderJson(parsed),
      };
    }
    if (capability === "Automatic Speech Recognition") {
      return { text: result?.text || "", html: DOMPurify.sanitize(marked.parse(result?.text || JSON.stringify(result, null, 2))) };
    }
    if (capability === "Voice Activity Detection") {
      return { text: JSON.stringify(result), html: renderJson(result) };
    }
    if (capability === "Translation") {
      const text = result?.translated_text || "";
      return { text, html: DOMPurify.sanitize(marked.parse(text || JSON.stringify(result, null, 2))) };
    }
    if (capability === "Summarization") {
      const text = result?.summary || "";
      return { text, html: DOMPurify.sanitize(marked.parse(text || JSON.stringify(result, null, 2))) };
    }
    if (["Image-to-Text", "Image Text to Text"].includes(capability)) {
      const text = result?.description || result?.response || "";
      return { text, html: DOMPurify.sanitize(marked.parse(text || JSON.stringify(result, null, 2))) };
    }
    if (["Text Classification", "Image Classification", "Object Detection", "Rerank"].includes(capability)) {
      return { text: JSON.stringify(result), html: renderScoreList(result?.response || result) };
    }
    if (capability === "Embeddings") {
      const shape = result?.shape || parsed?.data?.[0]?.embedding?.length;
      return { text: JSON.stringify(parsed), html: renderJson({ shape: shape || "unknown", preview: parsed?.data?.[0] || result }) };
    }
    return { text: JSON.stringify(parsed), html: renderJson(parsed) };
  }

  function extractTextGenerationResponse(parsed) {
    const result = parsed?.result ?? parsed;
    const contentParts = result?.content || parsed?.content || [];
    const outputParts = result?.output || parsed?.output || [];
    return parsed?.choices?.[0]?.message?.content
      || result?.choices?.[0]?.message?.content
      || parsed?.choices?.[0]?.text
      || result?.choices?.[0]?.text
      || result?.candidates?.[0]?.content?.parts?.map((part) => part?.text).filter(Boolean).join("\n")
      || parsed?.output_text
      || result?.output_text
      || outputParts.flatMap((item) => item?.content || []).map((part) => part?.text).filter(Boolean).join("\n")
      || contentParts.map((part) => part?.text).filter(Boolean).join("\n")
      || result?.response
      || result?.text
      || "";
  }

  async function buildNativeRunPayload(capability, endpoint_name, prompt, max_tokens) {
    const source_language = ($('#inference_source_language').val() || "").trim();
    const target_language = ($('#inference_target_language').val() || "").trim();
    const top_k = parseInt($('#inference_top_k').val(), 10);
    const width = parseInt($('#inference_image_width').val(), 10);
    const height = parseInt($('#inference_image_height').val(), 10);
    const fileMode = selectedEndpointFileMode();
    const filePayload = await readFirstFile(document.getElementById('inference_files'), fileMode);
    const payload = { model: endpoint_name };

    switch (capability) {
      case "Text-to-Image":
        payload.prompt = prompt;
        if (Number.isInteger(width) && width > 0) payload.width = width;
        if (Number.isInteger(height) && height > 0) payload.height = height;
        break;
      case "Text-to-Speech":
        if (endpoint_name.startsWith("@cf/deepgram/")) {
          payload.text = prompt;
        } else {
          payload.prompt = prompt;
          payload.lang = source_language || "en";
        }
        break;
      case "Automatic Speech Recognition":
        if (!filePayload) throw new Error("Please upload an audio file.");
        payload.audio = filePayload;
        if (source_language) payload.source_lang = source_language;
        if (target_language) payload.target_lang = target_language;
        break;
      case "Voice Activity Detection":
        if (!filePayload) throw new Error("Please upload an audio file.");
        payload.audio = filePayload;
        break;
      case "Translation":
        payload.text = prompt;
        payload.source_lang = source_language || "en";
        payload.target_lang = target_language || "fr";
        break;
      case "Summarization":
        payload.input_text = prompt;
        if (Number.isInteger(max_tokens) && max_tokens > 0) payload.max_length = max_tokens;
        break;
      case "Rerank": {
        const contexts = ($('#inference_context').val() || "").split("\n").map((line) => line.trim()).filter(Boolean).map((text) => ({ text }));
        if (contexts.length === 0) throw new Error("Add at least one context document for rerank.");
        payload.query = prompt;
        payload.contexts = contexts;
        if (Number.isInteger(top_k) && top_k > 0) payload.top_k = top_k;
        break;
      }
      case "Text Classification":
        payload.text = prompt;
        break;
      case "Image Classification":
      case "Object Detection":
        if (!filePayload) throw new Error("Please upload an image file.");
        payload.image = filePayload;
        break;
      case "Image-to-Text":
        if (!filePayload) throw new Error("Please upload an image file.");
        payload.image = filePayload;
        if (prompt) payload.prompt = prompt;
        break;
      case "Image Text to Text":
        if (!filePayload) throw new Error("Please upload an image file.");
        payload.image = filePayload;
        payload.messages = [{ role: "user", content: prompt || "Describe this image." }];
        break;
      default:
        payload.input = prompt;
    }

    return payload;
  }


  const generate = async () => {
    if (activeRequest) {
      activeRequest.controller.abort();
      return;
    }
    $('#inference_error').prop('hidden', true);
    const system = $('#inference_system').val() || '';
    const prompt = $('#inference_prompt').val() || '';
    const endpoint_name = $('#inference_endpoint').val();
    const api_key = $('#inference_api_key').val();
    const numericValue = (id, fallback) => {
      const value = parseFloat($(id).val());
      return Number.isFinite(value) ? value : fallback;
    };
    const temperature = numericValue('#inference_temperature', 1);
    const top_p = numericValue('#inference_top_p', 1);
    const max_tokens = parseInt($('#inference_max_tokens').val(), 10);
    const response_format = $('#inference_response_format').val();
    if (!endpoint_name) return showError('Choose a model to start.');
    if (!api_key) return showError('Choose an inference API key to start.');
    const invalidField = $('#inference_config_advanced_settings input').toArray().find((field) => !field.checkValidity());
    if (invalidField) {
      $('#inference_settings').prop('open', true);
      invalidField.focus();
      return showError(invalidField.validationMessage);
    }
    const $selected_endpoint = selectedEndpointOption();
    const endpoint_url = $selected_endpoint.attr('data-url');
    const capability = selectedCapability();
    const fileOnlyTask = ['Automatic Speech Recognition', 'Voice Activity Detection', 'Image Classification', 'Object Detection', 'Image-to-Text', 'Image Text to Text'].includes(capability);
    if (!prompt.trim() && !fileOnlyTask) return showError('Write a message before sending.');
    const native_run = selectedEndpointUsesNativeRun();
    const embeddings_request = capability === 'Embeddings';
    const endpoint_api = selectedEndpointApi();
    const endpoint_provider = $selected_endpoint.attr('data-provider') || 'layerrail';
    const streams_response = !native_run && !embeddings_request && endpoint_api === 'chat' && endpoint_provider !== 'azure_foundry';
    const request_input_price = selectedEndpointNumber('data-input-price');
    const request_output_price = selectedEndpointNumber('data-output-price');
    const history = previous_messages.filter((message) => message.role === 'user' || message.content[0].text);
    const request = { controller: new AbortController(), orb: null, messageId: null };
    activeRequest = request;
    const signal = request.controller.signal;
    const ensureCurrent = () => {
      if (signal.aborted || activeRequest !== request) throw new DOMException('Request stopped.', 'AbortError');
    };
    setActivity('waiting', request);
    let finalState = 'idle';
    try {
      const messages = [];
      if (!native_run && !embeddings_request && system.length > 0) messages.push({ role: 'system', content: system });
      if (!native_run && !embeddings_request) messages.push(...history);
      const file_contents = !native_run && !embeddings_request ? await readFilesFromInput(document.getElementById('inference_files')) : [];
      ensureCurrent();
      const user_message = { role: 'user', content: [{ type: 'text', text: prompt || taskHintForCapability(capability) }, ...file_contents] };
      if (!native_run && !embeddings_request) messages.push(user_message);
      let request_payload;
      let request_path;
      if (native_run) {
        request_path = "/v1/run";
        request_payload = await buildNativeRunPayload(capability, endpoint_name, prompt, max_tokens);
      } else if (embeddings_request) {
        request_path = "/v1/embeddings";
        request_payload = {
          model: endpoint_name,
          input: prompt,
        };
      } else if (endpoint_api === "run") {
        request_path = "/v1/run";
        const run_messages = [];
        if (system.length > 0) {
          run_messages.push({ role: "system", content: system });
        }
        run_messages.push(...history.map((message) => ({
          role: message.role,
          content: message.content?.[0]?.text || "",
        })).filter((message) => message.content));
        run_messages.push({ role: "user", content: prompt });

        if (endpoint_name.startsWith("google/")) {
          request_payload = {
            model: endpoint_name,
            messages: run_messages,
            temperature: temperature,
            top_p: top_p,
          };
        } else {
          request_payload = {
            model: endpoint_name,
            messages: run_messages,
            stream: false,
            temperature: temperature,
            top_p: top_p,
          };
        }
        if (Number.isInteger(max_tokens) && max_tokens > 0) {
          request_payload.max_tokens = max_tokens;
        }
      } else if (endpoint_api === "responses") {
        request_path = "/v1/responses";
        request_payload = {
          model: endpoint_name,
          input: messages.filter((message) => message.role !== "system"),
          instructions: system || undefined,
          stream: false,
          temperature: temperature,
          top_p: top_p,
        };
        if (Number.isInteger(max_tokens) && max_tokens > 0) {
          request_payload.max_output_tokens = max_tokens;
        }
      } else if (endpoint_api === "messages") {
        request_path = "/v1/messages";
        request_payload = {
          model: endpoint_name,
          messages: messages.filter((message) => message.role !== "system"),
          system: system || undefined,
          stream: false,
          temperature: temperature,
          top_p: top_p,
        };
        if (Number.isInteger(max_tokens) && max_tokens > 0) {
          request_payload.max_tokens = max_tokens;
        }
      } else {
        request_path = "/v1/chat/completions";
        request_payload = {
          model: endpoint_name,
          messages: messages,
          stream: streams_response,
          temperature: temperature,
          top_p: top_p,
        };
        if (Number.isInteger(max_tokens) && max_tokens > 0) {
          request_payload.max_tokens = max_tokens;
        }
        if (response_format === "json_object") {
          request_payload.response_format = { type: "json_object" };
        }
        if (streams_response) {
          request_payload.stream_options = { include_usage: true };
        }
      }
      ensureCurrent();
      const payload = JSON.stringify(request_payload);
      if (new TextEncoder().encode(payload).length > 50 * 1024 * 1024) throw new Error('This request is too large. Reduce the attachments or conversation to under 50 MB.');
      if ($('#inference_prompt').val() === prompt) $('#inference_prompt').val('');
      $('#inference_files').val('');
      resizePrompt();
      updateAttachments();
      appendMessage(user_message);
      const assistant_message = { role: 'assistant', content: [{ type: 'text', text: '' }] };
      request.orb = appendMessage(assistant_message, true);
      request.messageId = previous_messages.length - 1;
      const assistant_message_id = request.messageId;
      const $assistant_message_container = $(`#inference_message_${assistant_message_id}`);
      setActivity('waiting', request);
      let content = '';
      let usage = null;
      const showResponse = (text, html) => {
        ensureCurrent();
        const follow = conversation.scrollHeight - conversation.scrollTop - conversation.clientHeight < 100;
        assistant_message.content[0].text = text;
        $assistant_message_container.html(html);
        $(`#copy_inference_message_${assistant_message_id}`).prop('hidden', !text);
        if (follow) scrollConversation(true);
      };
      const response = await fetch(`${endpoint_url}${request_path}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${api_key}` }, body: payload, signal,
      });
      ensureCurrent();
      if (!response.ok) {
        let detail = `The endpoint returned status ${response.status}.`;
        try {
          const body = await response.json();
          detail = body?.errors?.map((error) => error.message).join('; ') || body?.error?.message || (typeof body?.error === 'string' ? body.error : detail);
        } catch (_) { /* Keep the HTTP status for non-JSON error responses. */ }
        throw new Error(detail);
      }
      if (native_run || embeddings_request) {
        const parsed = await response.json();
        ensureCurrent();
        if (parsed?.error) throw new Error(parsed.error.message || String(parsed.error));
        const rendered = renderInferenceResult(parsed, capability);
        showResponse(rendered.text, rendered.html);
        usage = parsed?.usage || parsed?.result?.usage;
        content = rendered.text;
      } else if (!streams_response) {
        const parsed = await response.json();
        ensureCurrent();
        if (parsed?.error) throw new Error(parsed.error.message || String(parsed.error));
        content = visibleAnswer(extractTextGenerationResponse(parsed)).text;
        showResponse(content, DOMPurify.sanitize(marked.parse(content)));
        usage = parsed?.usage || parsed?.result?.usage;
      } else {
        for await (const frame of readEventStream(response.body)) {
          ensureCurrent();
          if (frame?.error) throw new Error(frame.error.message || String(frame.error));
          if (frame?.usage) usage = frame.usage;
          const delta = frame?.choices?.[0]?.delta;
          if (!delta) continue;
          content += delta.content || '';
          const answer = visibleAnswer(content);
          if (delta.reasoning_content || delta.reasoning || answer.thinking) {
            setActivity('reasoning', request);
          }
          if (answer.text) {
            setActivity('streaming', request);
            showResponse(answer.text, DOMPurify.sanitize(marked.parse(answer.text)));
          }
        }
      }
      ensureCurrent();
      const prompt_tokens = usage?.prompt_tokens ?? usage?.input_tokens ?? estimateTokenCount(request_payload);
      const completion_tokens = usage?.completion_tokens ?? usage?.output_tokens ?? (['Text-to-Image', 'Text-to-Speech', 'Embeddings'].includes(capability) ? 1 : estimateTokenCount(content));
      recordUsage(prompt_tokens, completion_tokens, assistant_message_id, request_input_price, request_output_price, endpoint_provider !== 'azure_foundry');
      if (!usage) $(`#inference_message_info_${assistant_message_id}`).prepend('Estimated tokens. ');
      if (!assistant_message.content[0].text) $(`#inference_message_info_${assistant_message_id}`).prepend('The model returned no answer. Try again or raise the output limit. ');
      finalState = 'complete';
      announce('Response complete.');
    } catch (error) {
      if (activeRequest !== request) return;
      finalState = signal.aborted ? 'stopped' : 'error';
      const message = signal.aborted ? 'Response stopped.' :
        error instanceof TypeError && error.message === 'Failed to fetch' ? 'Could not reach the model. Check your connection and try again.' : error.message || String(error);
      if (request.messageId !== null) $(`#inference_message_info_${request.messageId}`).text(message);
      if (!signal.aborted) showError(message);
      announce(message);
      // Restore a failed prompt when the user has not already started a new draft.
      if (!signal.aborted && !$('#inference_prompt').val()) { $('#inference_prompt').val(prompt); resizePrompt(); }
    } finally {
      effects.orb(request.orb, null);
      if (request.orb) request.orb.hidden = true;
      if (activeRequest === request) {
        activeRequest = null;
        setActivity(finalState);
      }
    }
  };

  $('#inference_submit').on("click", generate);
  $('#inference_prompt_template').on("change", applyPromptTemplate);
  $('[data-prompt-template]').on('click', function () {
    $('#inference_prompt_template').val($(this).attr('data-prompt-template'));
    applyPromptTemplate();
  });
  $('#inference_prompt').on('input', resizePrompt).on('keydown', (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter' && !event.originalEvent?.isComposing) {
      event.preventDefault();
      if (!activeRequest) generate();
    }
  });
  $('#inference_attach').on('click', () => document.getElementById('inference_files').click());
  $('#inference_files').on('change', updateAttachments);
  $('#inference_clear_files').on('click', () => { $('#inference_files').val(''); updateAttachments(); });
  window.addEventListener('pagehide', () => { activeRequest?.controller.abort(); });
  updateMessageCount();
  updateUsagePanel();
}
