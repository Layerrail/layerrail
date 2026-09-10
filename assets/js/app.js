$(function () {
  setupAutoRefresh();
  setupScrollToBottom();
  setupDatePicker();
  setupFormOptionUpdates();
  setupInferenceCatalog();
  setupMetricsCharts();
  setupPgConfigCard();
  setupStructuredDataCard();
  setupLogDestinationForm();
  setupConsoleNoticeBanner();
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

function setupConsoleNoticeBanner() {
  $(".console-notice-banner").each(function () {
    const banner = $(this);
    const key = banner.data("console-notice-key");
    const storageKey = "layerrail-console-notice-dismissed-" + key;

    if (window.localStorage && localStorage.getItem(storageKey) === "1") {
      banner.remove();
      return;
    }

    banner.find(".console-notice-dismiss").on("click", function () {
      if (window.localStorage) {
        localStorage.setItem(storageKey, "1");
      }
      banner.slideUp(120, function () {
        banner.remove();
      });
    });
  });
}
