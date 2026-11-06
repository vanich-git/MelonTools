#!/usr/bin/env python3
"""Opt-in real GGUF + llama router + gateway smoke; all state is temporary."""
import argparse
import pathlib
import subprocess
import tempfile

from test_local_ai_gateway import LOCAL_TOKEN, free_port, request, run_fixture, until


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=pathlib.Path, required=True)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--model", type=pathlib.Path, required=True)
    parser.add_argument("--fixture", type=pathlib.Path, action="append", required=True)
    args = parser.parse_args()
    model = args.model.resolve(strict=True)
    runtime = args.runtime.resolve(strict=True)
    model_id = "local/e2e-publication"
    with tempfile.TemporaryDirectory(prefix="melon-runtime-gateway-e2e-") as directory:
        root = pathlib.Path(directory)
        preset = root / "models.ini"
        preset.write_text(f'''[{model_id}]
model = {model}
alias = {model_id}
ctx-size = 4096
batch-size = 256
n-gpu-layers = 99
flash-attn = on
reasoning = off
cache-type-k = f16
cache-type-v = f16
threads = 4
''')
        port = free_port()
        with (root / "runtime.log").open("w+") as log:
            process = subprocess.Popen([
                str(runtime), "--host", "127.0.0.1", "--port", str(port),
                "--api-key", LOCAL_TOKEN, "--models-preset", str(preset),
                "--models-max", "1", "--parallel", "1", "--metrics",
            ], cwd=root, stdout=log, stderr=log)
            try:
                until(lambda: request(port, "/health", token=LOCAL_TOKEN), process, timeout=60)
                def loaded():
                    data = request(port, "/models", token=LOCAL_TOKEN)
                    return any(m.get("id") == model_id and m.get("status", {}).get("value") == "loaded" for m in data.get("data", []))

                def load_model():
                    request(port, "/models/load", {"model": model_id}, token=LOCAL_TOKEN)
                    until(loaded, process, timeout=180)
                    print("PASS real llama-server: requested model loaded")

                def unload_model():
                    request(port, "/models/unload", {"model": model_id}, token=LOCAL_TOKEN)
                    until(lambda: not loaded(), process)
                    print("PASS real llama-server: requested model unloaded")

                for fixture in args.fixture:
                    # Each gateway cycle follows actual residency: load first,
                    # then publish; unload first, then remove the public route.
                    run_fixture(args.engine.resolve(), fixture, port, model_id, model_id,
                                before_publish=load_model, after_chat=unload_model)
            except Exception:
                log.flush()
                log.seek(0)
                print(log.read()[-10000:].replace(LOCAL_TOKEN, "[upstream]"))
                raise
            finally:
                # Killing the router also terminates its owned model subprocess.
                process.terminate()
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    print("PASS real runtime + real gateway gate")


if __name__ == "__main__":
    main()
