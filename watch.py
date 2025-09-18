import sys
import time
import subprocess
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler


class ZigBuildEventHandler(FileSystemEventHandler):
    def on_modified(self, event):
        if event.is_directory or not event.src_path.endswith(".zig"):
            return

        if ".zig-cache" in event.src_path or "zig-out" in event.src_path:
            return

        print(f"File modified: {event.src_path}. Running zig fmt and zig build...", flush=True)
        try:
            subprocess.run(["zig", "fmt", event.src_path], check=True)
            subprocess.run(["zig", "build", "run"], check=True)
            print("Build successful.", flush=True)
        except subprocess.CalledProcessError as e:
            print(f"An error occurred: {e}", flush=True)
        except FileNotFoundError:
            print("Error: 'zig' command not found. Make sure Zig is installed and in your PATH.", flush=True)


if __name__ == "__main__":
    path = "."
    event_handler = ZigBuildEventHandler()
    observer = Observer()
    observer.schedule(event_handler, path, recursive=True)
    observer.start()

    subprocess.run(["zig", "build", "run"], check=True)
    print(f"Watching for file changes in {path}")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()
