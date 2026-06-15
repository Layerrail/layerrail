$(function () {
  setupAutoRefresh();
  setupScrollToBottom();
  setupDatePicker();
  setupFormOptionUpdates();
  setupInferenceCatalog();
  setupPlayground();
  setupMetricsCharts();
  setupPgConfigCard();
  setupStructuredDataCard();
  setupLogDestinationForm();
});

$(".toggle-mobile-menu").on("click", function (event) {
  let menu = $("#mobile-menu")
  if (menu.is(":hidden")) {
    menu.show(0, function () {
      menu.toggleClass("mobile-menu-open")
    });
  } else {
    menu.toggleClass("mobile-menu-open")
    setTimeout(function () {
      menu.hide();
    }, 300);
  }
});

$(".cache-group-row").on("click", function (event) {
  let repository = $(this).data("repository");
  $(this).toggleClass("active");
  $(".cache-group-" + repository).toggleClass("hidden");
});


$(document).click(function () {
  $(".dropdown").removeClass("active");
});

$(".dropdown").on("click", function (event) {
  event.stopPropagation();
  $(this).toggleClass("active");
});

$(".toggle-parent-to-active").on("click", function (event) {
  $(this).parent().toggleClass("active");
});

$("#tag-membership-add tr, #tag-membership-remove tr").on("click", function (event) {
  let checkbox = $(this).find("input[type=checkbox]");
  if ($(event.target).is("input") || checkbox.prop("disabled")) {
    return;
  }
  checkbox.prop("checked", !checkbox.prop("checked"));
});

$("#ace-template").addClass('hidden');

var num_aces = 0;
$("#new-ace-btn").on("click", function (event) {
  event.preventDefault();
  num_aces++;
  var template = $('#ace-template').clone().removeClass('hidden').removeAttr('id');
  var pos = 0;
  var id_attr = '';
  template.find('select, input').each(function (i, element) {
    id_attr = 'ace-select-' + num_aces + '-' + pos;
    pos++;
    $(element).attr('id', id_attr);
  });
  template.find('label').attr('for', id_attr);
  template.insertBefore('#access-control-entries tbody tr:last');
});

$(".delete-btn").on("click", function (event) {
  let confirmation = $(this).data("confirmation");
  let confirmationMessage = $(this).data("confirmation-message") || "Are you sure to delete?";

  if (confirmation) {
    if (prompt(`${confirmationMessage}\nPlease type "${confirmation}" to confirm deletion`, "") != confirmation) {
      alert("Could not confirm resource name");
      event.preventDefault();
      return;
    }
  } else if (!confirm(confirmationMessage)) {
    event.preventDefault();
    return;
  }

  return true;
});

$(".restart-btn").on("click", function (event) {
  if (!confirm("Are you sure to restart?")) {
    event.preventDefault();
  }
});

$(".copyable-content").on("click", ".copy-button", function (event) {
  let parent = $(this).parent();
  let content = parent.data("content");
  let message = parent.data("message");
  navigator.clipboard.writeText(content);

  if (message) {
    notification(message);
  }
})

$(".revealable-button").on("click", function () {
  $(this).closest(".revealable-content").toggleClass("active");
})

$(".back-btn").on("click", function (event) {
  event.preventDefault();
  history.back();
})

function notification(message) {
  let container = $("#notification-template").parent();
  let newNotification = $("#notification-template").clone();
  newNotification.find("p").text(message);
  newNotification.appendTo(container).show(0, function () {
    $(this)
      .removeClass("translate-y-2 opacity-0 sm:translate-y-0 sm:translate-x-2")
      .addClass("translate-y-0 opacity-100 sm:translate-x-0");
  });

  setTimeout(function () {
    newNotification.remove();
  }, 2000);
}

function setupAutoRefresh() {
  $("div.auto-refresh").each(function () {
    const interval = $(this).data("interval");
    setTimeout(function () {
      location.reload();
    }, interval * 1000);
  });
}

function setupScrollToBottom() {
  $("[data-scroll-to-bottom]").each(function () {
    this.scrollTop = this.scrollHeight;
  });
}

function setupDatePicker() {
  if (!$.prototype.flatpickr) { return; }

  $(".datepicker").each(function () {
    let options = {
      enableTime: true,
      time_24hr: true,
      altInput: true,
      altFormat: "F j, Y H:i \\U\\T\\C",
      dateFormat: "Y-m-d H:i",
      monthSelectorType: "static",
      parseDate(dateStr, dateFormat) {
        // flatpicker uses browser timezone, but we want to customer to select UTC
        date = new Date(dateStr);
        return new Date(date.getUTCFullYear(), date.getUTCMonth(),
          date.getUTCDate(), date.getUTCHours(),
          date.getUTCMinutes(), date.getUTCSeconds());
      }
    };

    if ($(this).data("maxdate")) {
      options.maxDate = $(this).data("maxdate");
    }
    if ($(this).data("mindate")) {
      options.minDate = $(this).data("mindate");
    }
    if ($(this).data("defaultdate")) {
      options.defaultDate = $(this).data("defaultdate");
    }
    if ($(this).data("dateformat")) {
      options.dateFormat = $(this).data("dateformat");
    }

    $(this).flatpickr(options);
  });
}

$(".fork-icon").on("click", function () {
  let target_datetime = $(this).data("target-datetime");
  date_picker = flatpickr("#restore_target", {enableTime: true, dateFormat: "Y-m-d H:i"})
  date_picker.setDate(target_datetime, true);

  $("#restore_target").addClass("animate-flash transition-colors duration-1000");
  setTimeout(() => {
    $("#restore_target").removeClass('animate-flash');
  }, 2000);
})

$(".connection-info-format-selector select, .connection-info-format-selector input").on('change', function() {
  let format = $(".connection-info-format-selector select").val();
  let port = $(".connection-info-format-selector input").is(":checked") ? "6432" : "5432";
  let reveal_status = $(".connection-info-box:visible").find(".group").hasClass('active')

  $(".connection-info-box").hide();
  $(".connection-info-box-" + format + "-" + port).find(".group").toggleClass('active', reveal_status);
  $(".connection-info-box-" + format + "-" + port).show();
});


function setupFormOptionUpdates() {
  $('#creation-form').on('change', 'input', function () {
    let name = $(this).attr('name');
    option_dirty[name] = $(this).val().replace(/\./g, '-');

    if ($(this).attr('type') !== 'radio') {
      return;
    }
    redrawChildOptions(name);
  });
}

function redrawChildOptions(name) {
  if (option_children[name]) {
    let value = $("input[name=" + name + "]:checked").val().replace(/\./g, '-');
    let classes = $("input[name=" + name + "]:checked").parent().attr('class');
    classes = classes ? classes.split(" ") : [];
    classes = "." + classes.concat("form_" + name, "form_" + name + "_" + value).join('.');

    option_children[name].forEach(function (child_name) {
      let child_type = document.getElementsByName(child_name)[0].nodeName.toLowerCase();
      if (child_type == "input") {
        child_type = "input_" + document.getElementsByName(child_name)[0].type.toLowerCase();
      }

      let elements2select = [];
      switch (child_type) {
        case "input_radio":
          $("input[name=" + child_name + "]").parent().hide()
          $("input[name=" + child_name + "]").prop('disabled', true).prop('checked', false).prop('selected', false);
          $("input[name=" + child_name + "]").parent(classes).show()
          $("input[name=" + child_name + "]").parent(classes).children("input[name=" + child_name + "]").prop('disabled', false);

          if (option_dirty[child_name]) {
            elements2select = $("input[name=" + child_name + "][value=" + option_dirty[child_name] + "]").parent(classes);
          }

          if (elements2select.length == 0) {
            option_dirty[child_name] = null;
            elements2select = $("input[name=" + child_name + "]").parent(classes);
          }

          elements2select[0].children[0].checked = true;
          break;
        case "input_checkbox":

          break;
        case "select":
          $("select[name=" + child_name + "]").children().hide().prop('disabled', true).prop('checked', false).prop('selected', false);
          $("select[name=" + child_name + "]").children(".always-visible, " + classes).show().prop('disabled', false);

          if (option_dirty[child_name]) {
            elements2select = $("select[name=" + child_name + "]").children(classes + "[value=" + option_dirty[child_name] + "]");
          }

          if (elements2select.length == 0) {
            option_dirty[child_name] = null;
            elements2select = $("select[name=" + child_name + "]").children(".always-visible, " + classes);
          }

          elements2select[0].selected = true;
          break;
      }

      redrawChildOptions(child_name);
    });
  }
}

function setupInferenceCatalog() {
  const $catalog = $('#inference_model_catalog');
  if ($catalog.length === 0) {
    return;
  }

  const $cards = $('[data-inference-model-card]');
  const $empty = $('#inference_catalog_empty');
  const $search = $('#inference_model_search');
  const $capability = $('#inference_capability_filter');

  function filterCatalog() {
    const query = ($search.val() || '').toString().trim().toLowerCase();
    const capability = ($capability.val() || '').toString();
    let visibleCount = 0;

    $cards.each(function () {
      const $card = $(this);
      const matchesQuery = query === '' || ($card.data('search') || '').includes(query);
      const matchesCapability = capability === '' || $card.data('capability') === capability;
      const visible = matchesQuery && matchesCapability;
      $card.toggleClass('hidden', !visible);
      if (visible) {
        visibleCount += 1;
      }
    });

    $empty.toggleClass('hidden', visibleCount !== 0 || $cards.length === 0);
  }

  $search.on('input', filterCatalog);
  $capability.on('change', filterCatalog);
}

function setupPlayground() {
  if ($('#inference_submit').length === 0) {
    return;
  }

  const previous_messages = [];
  const previous_message_containers = [];
  const session_usage = { prompt_tokens: 0, completion_tokens: 0, cost: 0 };
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
    ].includes(selectedCapability());
  }

  function selectedEndpointFileMode() {
    const capability = selectedCapability();
    if (capability === "Automatic Speech Recognition") return "audio";
    if (["Image Classification", "Object Detection", "Image-to-Text"].includes(capability)) return "image-bytes";
    if (capability === "Image Text to Text") return "image-base64";
    if (selectedTags()['multimodal']) return "chat-multimodal";
    return "none";
  }

  function taskHintForCapability(capability) {
    return {
      "Text Generation": "Chat with a text model using the OpenAI-compatible chat route.",
      "Embeddings": "Create vectors from text using the OpenAI-compatible embeddings route.",
      "Text-to-Image": "Generate an image from a prompt. Advanced settings can set width and height.",
      "Text-to-Speech": "Generate speech audio from text. Set language in advanced settings when needed.",
      "Automatic Speech Recognition": "Upload an audio file and transcribe it with Workers AI.",
      "Translation": "Translate the prompt text. Set source and target language in advanced settings.",
      "Summarization": "Summarize long text. Max output tokens controls summary length.",
      "Rerank": "Use the prompt as the query and add one document per line in extra context.",
      "Text Classification": "Classify the prompt text and return labels with confidence scores.",
      "Image Classification": "Upload an image and classify what it contains.",
      "Object Detection": "Upload an image and detect objects with bounding boxes.",
      "Image-to-Text": "Upload an image and ask for a description.",
      "Image Text to Text": "Upload an image and ask a question about it.",
    }[capability] || "Run this model through the native Workers AI route.";
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
    $('#inference_session_message_count').text(`${count} message${count === 1 ? "" : "s"} in this session`);
  }

  function updateUsagePanel() {
    $('#inference_session_usage').text(`${formatTokenCount(session_usage.prompt_tokens)} input tokens and ${formatTokenCount(session_usage.completion_tokens)} output tokens`);
    $('#inference_session_cost').text(formatEstimatedCost(session_usage.cost));
  }

  function updateFreeQuotaDisplay() {
    $('[data-free-quota-value]').each(function () {
      $(this).attr('data-free-quota-value', remaining_free_quota);
      $(this).text(formatTokenCount(remaining_free_quota));
    });
  }

  function recordUsage(prompt_tokens, completion_tokens, message_id, input_price, output_price) {
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
    remaining_free_quota = Math.max(remaining_free_quota - total_tokens, 0);
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
    if (selected === "json") {
      $('#inference_response_format').val("json_object");
    }
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
    $files.prop('disabled', mode === "none");
    if (mode === "audio") {
      $files.attr('accept', ".wav,.mp3,.m4a,.ogg,.webm");
    } else if (["image-bytes", "image-base64", "chat-multimodal"].includes(mode)) {
      $files.attr('accept', ".jpg,.jpeg,.png,.webp");
    } else {
      $files.attr('accept', "");
    }
  }

  function syncSelectedEndpoint() {
    const capability = selectedCapability();
    update_file_input_state();
    updateSelectedModelDetails();
    updateUsagePanel();
    $('#inference_task_hint').text(taskHintForCapability(capability));
    $('#inference_context_container').toggleClass("hidden", capability !== "Rerank");
    const promptLabel = capability === "Embeddings" ? "Input text" :
      capability === "Rerank" ? "Query" :
      ["Image Classification", "Object Detection", "Automatic Speech Recognition"].includes(capability) ? "Optional prompt" :
      "New Message";
    $('label[for="inference_prompt"]').text(promptLabel);
  }

  syncSelectedEndpoint();
  $('#inference_endpoint').on('change', syncSelectedEndpoint);

  $("#inference_new_chat").click(() => {
    for (const container of previous_message_containers) {
      container.remove();
    }
    previous_messages.splice(0);
    previous_message_containers.splice(0);
    $("#inference_previous_empty").show();
    session_usage.prompt_tokens = 0;
    session_usage.completion_tokens = 0;
    session_usage.cost = 0;
    $('#inference_last_usage').text("No usage yet");
    updateMessageCount();
    updateUsagePanel();
  });

  // Show reasoning in a different style.
  const reasoningExtension = {
    name: "reasoning",
    level: "block",
    format_reasoning(text) {
      text = text.trim().replace(/\n+/g, '<br>');
      if (text.length > 0) {
        return `
          <div class="text-sm italic p-4 bg-gray-50 mb-2">
            <div class="font-bold mb-4">Reasoning</div>
            ${text}
          </div>`;
      }
      return "";
    },
    tokenizer(src) {
      const match = src.match(/^<think>([\s\S]+?)(?:<\/think>|$)/);
      if (match) {
        return {
          type: "reasoning",
          raw: match[0],
          text: match[1].trim(),
        };
      }
      return false;
    },
    renderer(token) {
      if (token.type === "reasoning") {
        return reasoningExtension.format_reasoning(token.text);
      }
    }
  };
  marked.use({ extensions: [reasoningExtension] });

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
    const PROCESSING_STATUS = "<span class='mask-sweep'>Processing...</span>";
    const num_files = message.content.length - 1;
    const $new_message = $(`
      <div class="mt-6 first:mt-2">
        <div class="inline-flex items-baseline rounded-full px-2 text-xs font-semibold leading-5 bg-gray-200 text-gray-800">${role}</div>
        <div id="inference_message_${message_id}" class="mt-2 text-sm ml-2">${text}</div>
        <div class="text-sm ml-2 mt-1 text-gray-500">${num_files > 0 ? `Attached ${num_files} file(s).` : ""}</div>
        <div id="inference_message_info_${message_id}" class="text-sm ml-2 mt-1 text-gray-500">${show_processing ? PROCESSING_STATUS : ""}</div>
        <div class="flex mt-2 gap-1 ml-2 items-center">
          <div id="copy_inference_message_${message_id}" class="group inline-block text-gray-400 hover:text-black cursor-pointer">
            <svg id="inference_icon_${message_id}" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="2" stroke="currentColor" class="h-4 w-4">
              ${COPY_ICON}
            </svg>
          </div>
        </div>
      </div>
    `);
    $("#inference_previous_empty").hide();
    $("#inference_previous").append($new_message);
    previous_message_containers.push($new_message);
    previous_messages.push(message);
    updateMessageCount();
    let timeout = undefined;
    $(`#copy_inference_message_${message_id}`).click(() => {
      const content = previous_messages[message_id].content[0].text;
      window.navigator.clipboard.writeText(content);
      $(`#inference_icon_${message_id}`).html(CHECK_ICON);
      clearTimeout(timeout);
      timeout = setTimeout(() => {
        $(`#inference_icon_${message_id}`).html(COPY_ICON);
      }, 1000);
    });
  }

  function renderJson(value) {
    return `<pre class="max-w-full overflow-x-auto rounded-lg bg-gray-800 p-3 text-xs text-white sm:text-sm">${DOMPurify.sanitize(JSON.stringify(value, null, 2))}</pre>`;
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
        payload.prompt = prompt;
        payload.lang = source_language || "en";
        break;
      case "Automatic Speech Recognition":
        if (!filePayload) throw new Error("Please upload an audio file.");
        payload.audio = filePayload;
        if (source_language) payload.source_lang = source_language;
        if (target_language) payload.target_lang = target_language;
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

  let controller = null;
  const generate = async () => {
    if (controller) {
      controller.abort();
      $('#inference_submit').text("Submit");
      update_file_input_state();
      controller = null;
      return;
    }

    const system = $('#inference_system').val();
    const prompt = $('#inference_prompt').val();
    const endpoint_name = $('#inference_endpoint').val();
    const api_key = $('#inference_api_key').val();
    const temperature = parseFloat($('#inference_temperature').val()) || 1.0;
    const top_p = parseFloat($('#inference_top_p').val()) || 1.0;
    const max_tokens = parseInt($('#inference_max_tokens').val(), 10);
    const response_format = $('#inference_response_format').val();

    if (!endpoint_name) {
      alert("Please select an inference endpoint.");
      return;
    }
    if (!api_key) {
      alert("Please select an inference api key.");
      return;
    }

    const $selected_endpoint = $('#inference_endpoint option:selected');
    const endpoint_url = $selected_endpoint.attr('data-url');
    const capability = selectedCapability();
    const fileOnlyTask = ["Automatic Speech Recognition", "Image Classification", "Object Detection"].includes(capability);
    if (!prompt && !fileOnlyTask) {
      alert("Please enter a prompt.");
      return;
    }
    const native_run = selectedEndpointUsesNativeRun();
    const embeddings_request = capability === "Embeddings";
    const endpoint_api = selectedEndpointApi();
    const streams_response = !native_run && !embeddings_request && endpoint_api === "chat" && $selected_endpoint.attr('data-provider') !== "cloudflare";
    const request_input_price = selectedEndpointNumber('data-input-price');
    const request_output_price = selectedEndpointNumber('data-output-price');

    const messages = [];
    if (!native_run && !embeddings_request && system.length > 0) {
      messages.push({ role: "system", content: system });
    }
    if (!native_run && !embeddings_request) {
      messages.push(...previous_messages);
    }
    let file_contents = [];
    if (!native_run && !embeddings_request) {
      try {
        file_contents = await readFilesFromInput(document.getElementById('inference_files'));
      } catch (error) {
        alert(`Failed to read file(s): ${error.message || error}`);
        return;
      }
    }
    const user_message = {
      role: "user", content: [
        { type: "text", text: prompt || taskHintForCapability(capability) },
        ...file_contents,
      ]
    };
    if (!native_run && !embeddings_request) {
      messages.push(user_message);
    }

    let request_payload;
    let request_path;
    try {
      if (native_run) {
        request_path = "/v1/run";
        request_payload = await buildNativeRunPayload(capability, endpoint_name, prompt, max_tokens);
      } else if (embeddings_request) {
        request_path = "/v1/embeddings";
        request_payload = {
          model: endpoint_name,
          input: prompt,
        };
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
    } catch (error) {
      alert(error.message || error);
      return;
    }
    const payload = JSON.stringify(request_payload);

    const MAX_PAYLOAD_MB = 50;
    if (payload.length > MAX_PAYLOAD_MB << 20) {
      alert(`The request payload is too large (${payload.length >> 20} MB).`
        + ` Please reduce the size to less than ${MAX_PAYLOAD_MB} MB.`);
      return;
    }

    $("#inference_submit").text("Stop");
    $("#inference_files").prop('disabled', true);
    $("#inference_prompt").val("");
    $("#inference_files").val("");
    appendMessage(user_message);
    appendMessage({
      role: "assistant",
      content: [
        { type: "text", text: "" }, // Placeholder for the response content.
      ]
    }, show_processing = true);
    const assistant_message_id = previous_messages.length - 1;
    const assistant_message = previous_messages[assistant_message_id];
    const $assistant_message_container = $(`#inference_message_${assistant_message_id}`);

    controller = new AbortController();
    const signal = controller.signal;
    let content = "";
    let reasoning_content = "";
    let showing_processing = true;

    try {
      const response = await fetch(`${endpoint_url}${request_path}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${api_key}`,
        },
        body: payload,
        signal,
      });

      if (!response.ok) {
        let error_detail = `Response status: ${response.status}`;
        try {
          const error_body = await response.json();
          error_detail = error_body?.errors?.map((err) => err.message).join("; ")
            || error_body?.error?.message
            || error_body?.error
            || error_detail;
        } catch (_) {
          // Keep the plain status when the server did not return JSON.
        }
        throw new Error(error_detail);
      }

      if (native_run || embeddings_request) {
        const parsed = await response.json();
        const rendered = renderInferenceResult(parsed, capability);
        const prompt_tokens = parsed?.usage?.prompt_tokens ?? estimateTokenCount(prompt || request_payload);
        const completion_tokens = parsed?.usage?.completion_tokens ?? (["Text-to-Image", "Text-to-Speech", "Embeddings"].includes(capability) ? 1 : estimateTokenCount(rendered.text || parsed));
        recordUsage(prompt_tokens, completion_tokens, assistant_message_id, request_input_price, request_output_price);

        assistant_message.content[0].text = rendered.text;
        $assistant_message_container.html(rendered.html);
        return;
      }

      if (!streams_response) {
        const parsed = await response.json();
        const usage = parsed?.usage || parsed?.result?.usage || {};
        content = extractTextGenerationResponse(parsed);
        const prompt_tokens = usage.prompt_tokens ?? usage.input_tokens ?? estimateTokenCount(request_payload);
        const completion_tokens = usage.completion_tokens ?? usage.output_tokens ?? estimateTokenCount(content);
        recordUsage(prompt_tokens, completion_tokens, assistant_message_id, request_input_price, request_output_price);

        assistant_message.content[0].text = content;
        const rendered_response = DOMPurify.sanitize(marked.parse(content));
        $assistant_message_container.html(rendered_response);
        return;
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder("utf-8");
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop(); // Save last (possibly incomplete) line for next iteration.

        // At the end of stream, buffer will either be empty or contain only '[DONE]',
        // because all complete lines would have been processed and '[DONE]' is a full line.
        // So there is no need to flush or process the buffer after the loop.

        const parsedLines = lines
          .filter((line) => line.startsWith("data:"))
          .map((line) => line.slice(5).trim())
          .filter((line) => line !== "" && line !== "[DONE]")
          .map((line) => { try { return JSON.parse(line); } catch { return null; } })
          .filter((x) => x !== null);

        parsedLines.forEach((parsedLine) => {
          const prompt_tokens = parsedLine?.usage?.prompt_tokens;
          const completion_tokens = parsedLine?.usage?.completion_tokens;
          if (prompt_tokens !== undefined && completion_tokens !== undefined) {
            recordUsage(prompt_tokens, completion_tokens, assistant_message_id, request_input_price, request_output_price);
          }
          const new_content = parsedLine?.choices?.[0]?.delta?.content;
          const new_reasoning_content = parsedLine?.choices?.[0]?.delta?.reasoning_content ?? parsedLine?.choices?.[0]?.delta?.reasoning;
          if (!new_content && !new_reasoning_content) {
            return;
          }
          content += new_content || "";
          reasoning_content += new_reasoning_content || "";
          assistant_message.content[0].text = content;

          // Scroll to the bottom of the page if the user is near the bottom.
          const scrollTop = window.scrollY || document.documentElement.scrollTop;
          if (document.documentElement.scrollHeight - (scrollTop + window.innerHeight) <= 1) {
            requestAnimationFrame(() => {
              window.scrollTo({ top: document.documentElement.scrollHeight });
            });
          }

          const rendered_response = DOMPurify.sanitize(
            reasoningExtension.format_reasoning(reasoning_content) + marked.parse(content));
          $assistant_message_container.html(rendered_response);
          if (showing_processing) {
            $(`#inference_message_info_${assistant_message_id}`).text("");
            showing_processing = false;
          }
        });
      }
    }
    catch (error) {
      let errorMessage;

      if (signal.aborted) {
        errorMessage = "Request aborted.";
      } else if (error instanceof TypeError && error.message === "Failed to fetch") {
        errorMessage = "Unable to get a response from the endpoint. This may be due to network connectivity or permission-related issues.";
      } else {
        errorMessage = `An error occurred: ${error.message}`;
      }

      $(`#inference_message_info_${assistant_message_id}`).text(errorMessage);
    } finally {
      $("#inference_submit").text("Submit");
      update_file_input_state();
      controller = null;
    }
  };

  $('#inference_submit').on("click", generate);
  $('#inference_prompt_template').on("change", applyPromptTemplate);
  $('#inference_config-show_advanced-0').on("change", function() {
    $('#inference_config_advanced_settings').toggleClass("hidden", !$(this).is(":checked"));
  });
  updateMessageCount();
  updateUsagePanel();
}

const metricsCharts = [];
const colorPalette = [
  {
    color: '#5470c6',
    class: 'blue-600'
  },
  {
    color: '#91cc75',
    class: 'green-400'
  },
  {
    color: '#fac858',
    class: 'amber-400'
  },
  {
    color: '#ee6666',
    class: 'red-400'
  },
  {
    color: '#73c0de',
    class: 'sky-300'
  },
  {
    color: '#3ba272',
    class: 'emerald-600'
  },
  {
    color: '#8B67F2',
    class: 'layerrail-500',
  }
];

function setupMetricsCharts() {
  const metricsContainer = document.querySelector('#metrics-container');
  if (!metricsContainer) {
    return;
  }

  const charts = document.querySelectorAll('#metrics-container [id$="-chart"]');

  charts.forEach(chart => {
    const metricKey = chart.getAttribute('data-metric-key');
    const chartInstance = {
      key: metricKey,
      unit: chart.getAttribute('data-metric-unit'),
      chart: echarts.init(chart)
    };
    metricsCharts.push(chartInstance);
    setupInitialChartOptions(chartInstance);
  });

  updateMetricsCharts();

  $('#metrics-container #time-range').on('change', updateMetricsCharts);
  $('#metrics-container #refresh-button').on('click', updateMetricsCharts);

  // Reload charts every 5 minutes.
  setInterval(updateMetricsCharts, 5 * 60 * 1000);
}

function setupInitialChartOptions(chartInstance) {
  const options = {
    color: colorPalette.map(p => p.color),
    tooltip: {
      trigger: 'axis',
      formatter: function (params) {
        const isoDate = toLocalISOString(new Date(params[0].value[0]));

        // Build the tooltip HTML
        let html = `<strong>${isoDate}</strong><br/>`;
        params.forEach((item) => {
          const value = unitFormatter(chartInstance.unit, 2)(item.value[1]);
          // Use the series color for the marker
          const colorClass = colorPalette[item.componentIndex % colorPalette.length].class;
          html += `
            <span class="text-${colorClass} text-right">● ${item.seriesName}</span><span class="ml-2">${value}<br/></span>
          `;
        });
        return html;
      }
    },
    xAxis: {
      type: 'time',
      splitLine: { show: true },
      axisLabel: {
        hideOverlap: true
      }
    },
    yAxis: {
      type: 'value',
      axisLabel: {
        formatter: unitFormatter(chartInstance.unit),
        showMaxLabel: chartInstance.unit === "%"
      },
      min: 0,
      max: (chartInstance.unit === "%") ? 100 : function (value) {
        return Math.max(10, Math.round(1.1 * value.max))
      }
    },
    grid: {
      containLabel: true,
      left: '0%',
      right: '2%',
      top: '10%',
      bottom: '0%',
    },
  }

  chartInstance.chart.setOption(options);

  window.addEventListener('resize', debounce(chartInstance.chart.resize, 300));
}

function queryAndUpdateChart(chartInstance, start_time, end_time) {
  const metricKey = chartInstance.key;
  const params = {
    key: metricKey,
    start: start_time.toISOString(),
    end: end_time.toISOString()
  }
  const queryString = new URLSearchParams(params).toString();
  const url = $("#metrics-container").data("metrics-url") + "/metrics?" + queryString;

  fetch(url, {headers: {'Accept': 'application/json'}})
    .then(response => response.json())
    .then(data => {
      const metrics = data.metrics || [];

      if (metrics.length === 0) {
        console.warn(`No metrics found for ${metricKey}`);
        return;
      }

      const metric = metrics[0];
      const chartSeries = [];

      for (const series of metric["series"]) {
        const values = series["values"];
        const seriesData = values.map(item => {
          const ts = item[0] * 1000;
          const value = Number(Number(item[1]).toFixed(2));
          return [ts, value]
        });
        const labelKeys = Object.keys(series["labels"]);
        const firstKey = labelKeys[0];
        const seriesName = series["labels"][firstKey] || series["labels"]["name"] || metric["name"];

        chartSeries.push({
          name: seriesName,
          type: 'line',
          data: seriesData,
          symbol: 'circle',
          smooth: true,
          itemStyle: {
            opacity: 0,
          },
          emphasis: {
            itemStyle: {
              opacity: 1,
            },
          },
        });
      }

      chartInstance.chart.hideLoading();
      chartInstance.chart.setOption({
        ...chartInstance.chart.getOption(),
        legend: {
          data: chartSeries.map(series => series.name),
          right: '2%',
        },
        xAxis: {
          type: 'time',
          min: start_time.getTime(),
          max: end_time.getTime()
        },
        series: chartSeries,
        graphic: [],
      }, true);
      chartInstance.chart.resize();
    })
    .catch(error => {
      chartInstance.chart.hideLoading();
      chartInstance.chart.setOption({
        graphic: {
          type: 'text',
          left: 'center',
          top: 'middle',
          style: {
            text: 'Failed to load data. Please refresh the charts to try again.',
            fontSize: 18,
            fill: '#c00'
          }
        }
      });

      console.error(`Error fetching data for ${metricKey}: ${error}`)
    });
}

function updateMetricsCharts() {
  const timeDuration = $('#metrics-container #time-range').val() || "1h";
  const timeDurationSeconds = durationToSeconds(timeDuration);
  const start_time = new Date(Date.now() - timeDurationSeconds * 1000);
  const end_time = new Date(Date.now());

  for (const chartInstance of metricsCharts) {
    chartInstance.chart.showLoading();
    queryAndUpdateChart(chartInstance, start_time, end_time);
  }
}

function durationToSeconds(durationStr) {
  const units = {
    "s": 1,
    "m": 60,
    "h": 60 * 60,
    "d": 24 * 60 * 60,
  };
  const count = parseInt(durationStr.slice(0, -1));
  const unit = durationStr.slice(-1);
  if (isNaN(count) || !units[unit]) {
    throw new Error("Invalid duration format");
  }
  return count * units[unit];
}

function bytesFormatter(unit, precision) {
  const unitParts = unit.split('/');
  const suffix = unitParts.length > 1 ? "/" + unitParts[1] : "";

  return function (value, index) {
    if (value >= 1024 ** 4) return flexiblePrecision(value / (1024 ** 4), precision) + ' TiB' + suffix;
    if (value >= 1024 ** 3) return flexiblePrecision(value / (1024 ** 3), precision) + ' GiB' + suffix;
    if (value >= 1024 ** 2) return flexiblePrecision(value / (1024 ** 2), precision) + ' MiB' + suffix;
    if (value >= 1024) return flexiblePrecision(value / 1024, precision) + ' KiB' + suffix;
    return value + ' bytes' + suffix;
  }
}

function opsFormatter(unit, precision) {
  const unitParts = unit.split('/');
  const suffix = unitParts.length > 1 ? "/" + unitParts[1] : "";
  const unitName = unitParts[0];

  return function (value, index) {
    if (value >= 1000 ** 3) return flexiblePrecision(value / (1000 ** 3), precision) + ' G ' + unitName + suffix;
    if (value >= 1000 ** 2) return flexiblePrecision(value / (1000 ** 2), precision) + ' M ' + unitName + suffix;
    if (value >= 1000) return flexiblePrecision(value / 1000, precision) + ' K ' + unitName + suffix;
    return value + ' ' + unitName + suffix;
  }
}

function unitFormatter(unit, precision = 0) {
  if (unit.startsWith("bytes")) {
    return bytesFormatter(unit, precision);
  } else if (unit == "IOPS" || unit.startsWith("ops") || unit.startsWith("count") || unit.startsWith("deadlock")) {
    return opsFormatter(unit, precision);
  } else {
    return function (value, index) {
      return value + ' ' + unit;
    }
  }
}

function toLocalISOString(date) {
  const pad = n => String(n).padStart(2, '0');
  const tz = -date.getTimezoneOffset();
  const sign = tz >= 0 ? '+' : '-';
  const tzH = pad(Math.floor(Math.abs(tz) / 60));
  const tzM = pad(Math.abs(tz) % 60);
  return (
    date.getFullYear() + '-' +
    pad(date.getMonth() + 1) + '-' +
    pad(date.getDate()) + 'T' +
    pad(date.getHours()) + ':' +
    pad(date.getMinutes()) + ':' +
    pad(date.getSeconds())
  );
}

function debounce(callback, delay = 1000) {
  let timeout;
  return (...args) => {
    clearTimeout(timeout);
    timeout = setTimeout(() => {
      callback(...args);
    }, delay);
  };
}

// Increase precision for values less than 10 if using 0 precision, to not
// repeat the same single-digit axis value multiple times.
function flexiblePrecision(value, precision) {
  const increasedPrecision = Math.max(1, precision);

  return (value < 10) ? value.toFixed(increasedPrecision) : value.toFixed(precision);
}

function addRowToConfigCard(card, key, value) {
  const placeholder = card.find(".config-placeholder-group");
  if (!placeholder.length) return;
  const newRow = placeholder.clone(true);
  newRow.data("config-id", (placeholder.data("config-id") || 0) + 1);
  newRow.find("input").prop("disabled", false);
  newRow.find("input").eq(0).val(key);
  newRow.find("input").eq(1).val(value);
  newRow.removeClass("hidden config-placeholder-group").addClass("config-group");
  placeholder.before(newRow);
}

function setupPgConfigCard() {
  $(".delete-config-btn").on("click", function (event) {
    const configGroup = $(this).closest(".group");
    configGroup.remove();
  });

  $(".add-config-btn").on("click", function (e) {
    e.preventDefault();
    const createConfigGroup = $(e.target).closest(".group");
    const keyInput = createConfigGroup.find("input").eq(0);
    const valueInput = createConfigGroup.find("input").eq(1);
    if (!keyInput[0].reportValidity()) return;
    addRowToConfigCard(createConfigGroup.parent(), keyInput.val(), valueInput.val());
    keyInput.val("");
    valueInput.val("");
  });
}

function setupStructuredDataCard() {
  function addKvRow(addBtn) {
    const newKvRow = $(addBtn).closest(".new-sd-kv-row");
    const group = $(addBtn).closest(".sd-id-group");
    const sdId = group.data("sd-id");
    const keyInput = newKvRow.find(".new-sd-key");
    const valueInput = newKvRow.find(".new-sd-value");
    const key = keyInput.val().trim();
    if (!key) return;

    const placeholder = group.find(".sd-kv-placeholder-row");
    const newRow = placeholder.clone(true);
    newRow.find('input[name="structured_data_ids[]"]').val(sdId).prop("disabled", false);
    newRow.find('input[name="structured_data_keys[]"]').val(key).prop("disabled", false);
    newRow.find('input[name="structured_data_values[]"]').val(valueInput.val()).prop("disabled", false);
    newRow.removeClass("sd-kv-placeholder-row hidden").addClass("sd-kv-row");

    group.find(".sd-kv-rows").append(newRow);
    keyInput.val("");
    valueInput.val("");
  }

  $(document).on("click", ".add-sd-id-btn", function (e) {
    e.preventDefault();
    const nameInput = $(this).siblings(".new-sd-id-name");
    const sdId = nameInput.val().trim();
    if (!sdId) return;

    const placeholder = $(".sd-id-placeholder-group");
    const newGroup = placeholder.clone(true);
    newGroup.attr("data-sd-id", sdId);
    newGroup.find(".sd-id-label").text(sdId);
    newGroup.removeClass("sd-id-placeholder-group hidden").addClass("sd-id-group");

    placeholder.before(newGroup);
    nameInput.val("");
  });

  $(document).on("click", ".add-sd-kv-btn", function (e) {
    e.preventDefault();
    addKvRow(this);
  });

  $(document).on("click", ".delete-sd-id-btn", function (e) {
    e.preventDefault();
    $(this).closest(".sd-id-group").remove();
  });

  $(document).on("click", ".delete-sd-kv-btn", function (e) {
    e.preventDefault();
    $(this).closest(".sd-kv-row").remove();
  });

  $(document).on("submit", "form:has(#sd-id-groups)", function () {
    $(".sd-id-group .add-sd-kv-btn").each(function () {
      addKvRow(this);
    });
  });
}

function setupLogDestinationForm() {
  function protocolFor(type) {
    return type === "otlp" ? "https://" : "tcp://";
  }

  function stripProtocol(url) {
    return url.replace(/^https?:\/\/|^tcp:\/\//, "");
  }

  $(document).on("change", "#log-destination-provider", function () {
    const selected = $(this).find("option:selected");
    const type = selected.data("type");
    const url = selected.data("url") || "";
    const headers = selected.data("headers") || [];

    $("#log-destination-type").val(type);
    $("#url-prefix").text(protocolFor(type));
    $("#url-display").val(url ? stripProtocol(url) : "");
    $("label[for='url-display']").text(type === "otlp" ? "OTLP Endpoint URL" : "Syslog TCP Endpoint");

    if (type === "otlp") {
      $("#log-destination-otlp-auth").removeClass("hidden");
      $("#log-destination-syslog-auth").addClass("hidden");
      const card = $("#log-destination-otlp-auth");
      card.find(".config-group").remove();
      headers.forEach(([key, value]) => addRowToConfigCard(card, key, value));
    } else {
      $("#log-destination-otlp-auth").addClass("hidden");
      $("#log-destination-syslog-auth").removeClass("hidden");
    }
  });

  $(document).on("submit", "form:has(#url-display)", function () {
    const prefix = $("#url-prefix").text();
    const suffix = $("#url-display").val();
    $("#url-hidden").val(prefix + suffix);
  });
}
