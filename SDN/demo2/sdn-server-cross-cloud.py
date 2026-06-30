#!/usr/bin/env python3

from flask import Flask, request, jsonify
import subprocess
from pathlib import Path
import os

app = Flask(__name__)

BASE_DIR = Path(__file__).resolve().parent
SCRIPT_PATH = BASE_DIR / "update_route_cross_cloud.sh"


def extract_first_ip(data, key):
    try:
        return data.get(key, [{}])[0].get("ip", None)
    except (IndexError, AttributeError, TypeError):
        return None


@app.route("/update-route-gnodeb", methods=["POST"])
def update_route_gnodeb():
    try:
        data = request.get_json()
        if not data:
            return jsonify({"error": "Invalid JSON"}), 400

        ip_n3_old = data.get("n3oldUPF")
        ip_n3 = extract_first_ip(data, "n3")
        ip_n4 = extract_first_ip(data, "n4")
        ip_n6 = extract_first_ip(data, "n6")

        # Keep old fallback behavior.
        if ip_n3 is None:
            ip_n3 = ip_n4

        if not ip_n3 or not ip_n3_old:
            return jsonify({
                "error": "Missing required IP",
                "ip_n3": ip_n3,
                "ip_n3_old": ip_n3_old,
            }), 400

        effective_target = os.environ.get("AZURE_TRANSPORT_IP", ip_n3)

        print("Received data:", data, flush=True)
        print("Mode: cross-cloud-ens5-output-dnat", flush=True)
        print("Payload New N3:", ip_n3, flush=True)
        print("Effective Target:", effective_target, flush=True)
        print("Old N3:", ip_n3_old, flush=True)
        print("N4:", ip_n4, flush=True)
        print("N6:", ip_n6, flush=True)

        result = subprocess.run(
            ["bash", str(SCRIPT_PATH), ip_n3, ip_n3_old],
            check=True,
            capture_output=True,
            text=True,
        )

        return jsonify({
            "message": "Cross-cloud route updated successfully",
            "mode": "ens5-output-dnat",
            "payload_n3": ip_n3,
            "effective_target": effective_target,
            "old_n3": ip_n3_old,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }), 200

    except subprocess.CalledProcessError as e:
        return jsonify({
            "error": "Route update script failed",
            "stdout": e.stdout,
            "stderr": e.stderr,
            "returncode": e.returncode,
        }), 500

    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
