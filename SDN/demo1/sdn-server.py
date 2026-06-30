from flask import Flask, request, jsonify
import os
import json

app = Flask(__name__)

@app.route('/update-route-gnodeb', methods=['POST'])
def update_route_gnodeB():
    try:
        # Parse the incoming JSON data
        data = request.get_json()
        if not data:
            return jsonify({"error": "Invalid JSON"}), 400

        # Perform your logic here with the received data
        # Example: print the received data
        print("Received data:", data)

        # Extract IP addresses with exception handling for missing keys
        ip_n3 = None
        ip_n4 = None
        ip_n6 = None
        ip_n3_old = None
        try:
            ip_n3_old = data.get('n3oldUPF')
        except (IndexError, AttributeError):
            print("Key 'n3oldUPF' is missing or invalid")

        try:
            ip_n3 = data.get('n3', [{}])[0].get('ip', None)
        except (IndexError, AttributeError):
            print("Key 'n3' is missing or invalid")

        try:
            ip_n4 = data.get('n4', [{}])[0].get('ip', None)
        except (IndexError, AttributeError):
            print("Key 'n4' is missing or invalid")

        try:
            ip_n6 = data.get('n6', [{}])[0].get('ip', None)
        except (IndexError, AttributeError):
            print("Key 'n6' is missing or invalid")

        # Print the extracted IPs
        print("IP for n3:", ip_n3)
        print("IP for n4:", ip_n4)
        print("IP for n6:", ip_n6)
        print("IP for previous N3:", ip_n3_old)

        # If ip_n3 is None the ip_n3 = ip_n4
        if ip_n3 is None:
            ip_n3 = ip_n4

        # execute the script bash to update the route
        os.system(f"bash update_route-plus-arp.sh {ip_n3} {ip_n3_old}")

        # Return a success response
        return jsonify({"message": "Route updated successfully"}), 200
    except Exception as e:
        # Handle any unexpected errors
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)
