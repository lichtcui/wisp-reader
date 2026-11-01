// NAPI shell for the on-device sherpa-onnx TTS probe.
//
// The CLI implementation is included with its entry point renamed so the
// measurement and signal checks stay identical between host and device runs.

#define main tts_probe_cli_main
#include "tts_probe.cc"
#undef main

#include <fstream>
#include <memory>
#include <new>
#include <stdexcept>

#include "napi/native_api.h"

namespace {

struct WorkData {
  napi_env env = nullptr;
  napi_deferred deferred = nullptr;
  napi_async_work async_work = nullptr;
  std::string manifest_path;
  std::string result_path;
  std::string error;
  std::string summary;
};

std::vector<std::string> Split(const std::string& value, char delimiter) {
  std::vector<std::string> parts;
  size_t begin = 0;
  while (true) {
    const size_t end = value.find(delimiter, begin);
    if (end == std::string::npos) {
      parts.push_back(value.substr(begin));
      return parts;
    }
    parts.push_back(value.substr(begin, end - begin));
    begin = end + 1;
  }
}

std::string ResolvePath(const std::string& base, const std::string& value) {
  if (value.empty() || value.front() == '/') {
    return value;
  }
  return base + "/" + value;
}

std::string ResolveList(const std::string& base, const std::string& value) {
  if (value.empty()) {
    return "";
  }
  std::string resolved;
  for (const std::string& part : Split(value, ',')) {
    if (!resolved.empty()) {
      resolved.push_back(',');
    }
    resolved += ResolvePath(base, part);
  }
  return resolved;
}

std::string ParentDirectory(const std::string& path) {
  const size_t slash = path.rfind('/');
  if (slash == std::string::npos) {
    return ".";
  }
  return slash == 0 ? "/" : path.substr(0, slash);
}

bool ParseManifestLine(const std::string& line, const std::string& base,
                       Options* opt, std::string* error) {
  const std::vector<std::string> fields = Split(line, '\t');
  if (fields.size() != 18) {
    *error = "manifest line must have 18 tab-separated fields, got " +
             std::to_string(fields.size());
    return false;
  }

  opt->family = fields[0];
  opt->label = fields[1];
  opt->text_id = fields[2];
  opt->model = ResolvePath(base, fields[3]);
  opt->vocoder = ResolvePath(base, fields[4]);
  opt->lexicon = ResolveList(base, fields[5]);
  opt->tokens = ResolvePath(base, fields[6]);
  opt->data_dir = ResolvePath(base, fields[7]);
  opt->dict_dir = ResolvePath(base, fields[8]);
  opt->rule_fsts = ResolveList(base, fields[9]);
  opt->voices = ResolvePath(base, fields[10]);
  opt->lang = fields[11];
  opt->text = fields[12];
  opt->output = ResolvePath(base, fields[13]);

  if (!ParseInt(fields[14], &opt->threads) ||
      !ParseInt(fields[15], &opt->sid) ||
      !ParseInt(fields[16], &opt->warmup) ||
      !ParseInt(fields[17], &opt->runs)) {
    *error = "manifest integer field is invalid";
    return false;
  }
  return Validate(*opt, error);
}

void WriteFailure(std::ostream& out, const Options& opt,
                  const std::string& error) {
  out << "{\"event\":\"failure\",\"schema\":1"
      << ",\"family\":\"" << JsonEscape(opt.family) << "\""
      << ",\"label\":\"" << JsonEscape(opt.label) << "\""
      << ",\"text_id\":\"" << JsonEscape(opt.text_id) << "\""
      << ",\"threads\":" << opt.threads
      << ",\"sid\":" << opt.sid
      << ",\"error\":\"" << JsonEscape(error) << "\"}"
      << std::endl;
}

bool RunGroup(const Options& opt, std::ostream& out, std::string* error) {
  SherpaOnnxOfflineTtsConfig config;
  BuildConfig(opt, &config);

  const auto load_start = std::chrono::steady_clock::now();
  std::unique_ptr<const SherpaOnnxOfflineTts,
                  decltype(&SherpaOnnxDestroyOfflineTts)>
      tts(SherpaOnnxCreateOfflineTts(&config),
          &SherpaOnnxDestroyOfflineTts);
  const double load_ms = MillisecondsSince(load_start);
  if (!tts) {
    *error = "SherpaOnnxCreateOfflineTts failed";
    return false;
  }

  const int model_sample_rate = SherpaOnnxOfflineTtsSampleRate(tts.get());
  const int num_speakers = SherpaOnnxOfflineTtsNumSpeakers(tts.get());
  if (model_sample_rate <= 0) {
    *error = "invalid model sample rate";
    return false;
  }

  SherpaOnnxGenerationConfig generation;
  std::memset(&generation, 0, sizeof(generation));
  generation.speed = opt.speed;
  generation.sid = opt.sid;
  generation.silence_scale = opt.silence_scale;

  std::vector<float> last_samples;
  int last_sample_rate = 0;
  int recorded_runs = 0;
  const int total_runs = opt.warmup + opt.runs;

  for (int i = 1; i <= total_runs; ++i) {
    const bool warmup = i <= opt.warmup;
    const auto start = std::chrono::steady_clock::now();
    std::unique_ptr<const SherpaOnnxGeneratedAudio,
                    decltype(&SherpaOnnxDestroyOfflineTtsGeneratedAudio)>
        audio(SherpaOnnxOfflineTtsGenerateWithConfig(
                  tts.get(), opt.text.c_str(), &generation, nullptr, nullptr),
              &SherpaOnnxDestroyOfflineTtsGeneratedAudio);
    const double wall_ms = MillisecondsSince(start);
    if (!audio || audio->samples == nullptr || audio->n <= 0 ||
        audio->sample_rate <= 0) {
      *error = "generation failed at run " + std::to_string(i);
      return false;
    }

    RunResult result;
    result.index = i;
    result.warmup = warmup;
    result.wall_ms = wall_ms;
    result.sample_rate = audio->sample_rate;
    result.sample_count = audio->n;
    result.metrics =
        Measure(audio->samples, audio->n, audio->sample_rate, wall_ms);
    PrintRun(out, opt, result, load_ms, num_speakers, model_sample_rate);
    out.flush();

    if (!warmup) {
      last_samples.assign(audio->samples, audio->samples + audio->n);
      last_sample_rate = audio->sample_rate;
      ++recorded_runs;
    }
  }

  if (last_samples.empty() || last_sample_rate <= 0) {
    *error = "no measured audio to write";
    return false;
  }
  if (!SherpaOnnxWriteWave(last_samples.data(),
                           static_cast<int32_t>(last_samples.size()),
                           last_sample_rate, opt.output.c_str())) {
    *error = "failed to write " + opt.output;
    return false;
  }

  out << std::fixed << std::setprecision(3)
      << "{\"event\":\"complete\",\"schema\":1"
      << ",\"family\":\"" << JsonEscape(opt.family) << "\""
      << ",\"label\":\"" << JsonEscape(opt.label) << "\""
      << ",\"text_id\":\"" << JsonEscape(opt.text_id) << "\""
      << ",\"threads\":" << opt.threads
      << ",\"sid\":" << opt.sid
      << ",\"warmup_runs\":" << opt.warmup
      << ",\"measured_runs\":" << recorded_runs
      << ",\"load_ms\":" << load_ms
      << ",\"model_sample_rate\":" << model_sample_rate
      << ",\"num_speakers\":" << num_speakers
      << ",\"output\":\"" << JsonEscape(opt.output) << "\"}"
      << std::endl;
  return true;
}

std::string RunManifest(const std::string& manifest_path,
                        const std::string& result_path) {
  std::ifstream manifest(manifest_path);
  if (!manifest) {
    throw std::runtime_error("cannot open manifest " + manifest_path);
  }
  std::ofstream result(result_path, std::ios::out | std::ios::trunc);
  if (!result) {
    throw std::runtime_error("cannot write result " + result_path);
  }

  const std::string base = ParentDirectory(manifest_path);
  int groups = 0;
  int failures = 0;
  std::string line;
  while (std::getline(manifest, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    if (line.empty() || line.front() == '#') {
      continue;
    }
    ++groups;
    Options opt;
    std::string error;
    if (!ParseManifestLine(line, base, &opt, &error)) {
      Options failed;
      failed.label = "manifest";
      failed.text_id = std::to_string(groups);
      failed.threads = 0;
      failed.sid = 0;
      WriteFailure(result, failed, error);
      ++failures;
      continue;
    }
    if (!RunGroup(opt, result, &error)) {
      WriteFailure(result, opt, error);
      ++failures;
    }
    result.flush();
  }

  const std::string summary =
      "{\"groups\":" + std::to_string(groups) +
      ",\"failures\":" + std::to_string(failures) + "}";
  result << "{\"event\":\"manifest_complete\",\"schema\":1"
         << ",\"groups\":" << groups
         << ",\"failures\":" << failures
         << ",\"result\":\"" << JsonEscape(result_path) << "\"}"
         << std::endl;
  result.close();

  std::ofstream done(result_path + ".done", std::ios::out | std::ios::trunc);
  if (!done) {
    throw std::runtime_error("cannot write completion marker");
  }
  done << summary << '\n';
  return summary;
}

void Execute(napi_env, void* data) {
  WorkData* work = static_cast<WorkData*>(data);
  try {
    work->summary = RunManifest(work->manifest_path, work->result_path);
  } catch (const std::exception& exc) {
    work->error = exc.what();
  }
}

void Complete(napi_env env, napi_status status, void* data) {
  std::unique_ptr<WorkData> work(static_cast<WorkData*>(data));
  napi_value value = nullptr;
  if (status == napi_ok && work->error.empty()) {
    napi_create_string_utf8(env, work->summary.c_str(), NAPI_AUTO_LENGTH,
                            &value);
    napi_resolve_deferred(env, work->deferred, value);
  } else {
    const std::string message =
        work->error.empty() ? "async work cancelled" : work->error;
    napi_value message_value = nullptr;
    napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH,
                            &message_value);
    napi_create_error(env, nullptr, message_value, &value);
    napi_reject_deferred(env, work->deferred, value);
  }
  napi_delete_async_work(env, work->async_work);
}

void GetUtf8Argument(napi_env env, napi_value value, std::string* out) {
  size_t length = 0;
  napi_get_value_string_utf8(env, value, nullptr, 0, &length);
  std::vector<char> buffer(length + 1);
  napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length);
  out->assign(buffer.data(), length);
}

napi_value RunManifestCallback(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  if (argc != 2) {
    napi_throw_type_error(env, nullptr,
                          "runManifest requires manifestPath and resultLogPath");
    return nullptr;
  }

  auto work = std::make_unique<WorkData>();
  work->env = env;
  GetUtf8Argument(env, argv[0], &work->manifest_path);
  GetUtf8Argument(env, argv[1], &work->result_path);

  napi_value promise = nullptr;
  napi_create_promise(env, &work->deferred, &promise);
  napi_value resource_name = nullptr;
  napi_create_string_utf8(env, "ttsprobe", NAPI_AUTO_LENGTH, &resource_name);
  if (napi_create_async_work(env, nullptr, resource_name, Execute, Complete,
                             work.get(), &work->async_work) != napi_ok) {
    napi_throw_error(env, nullptr, "failed to create async work");
    return nullptr;
  }
  WorkData* raw = work.release();
  if (napi_queue_async_work(env, raw->async_work) != napi_ok) {
    napi_delete_async_work(env, raw->async_work);
    napi_value message = nullptr;
    napi_value error = nullptr;
    napi_create_string_utf8(env, "failed to queue async work", NAPI_AUTO_LENGTH,
                            &message);
    napi_create_error(env, nullptr, message, &error);
    napi_reject_deferred(env, raw->deferred, error);
    return promise;
  }
  return promise;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor descriptor = {
      "runManifest", nullptr, RunManifestCallback, nullptr, nullptr, nullptr,
      napi_default, nullptr};
  napi_define_properties(env, exports, 1, &descriptor);
  return exports;
}

}  // namespace

NAPI_MODULE(libttsprobe, Init)
