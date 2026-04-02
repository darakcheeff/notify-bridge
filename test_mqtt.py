import paho.mqtt.client as mqtt
import json, time, sys

guid = "test-group-007"
messages_received = []

def on_connect(client, userdata, flags, rc):
    client.subscribe(f"bridge/{guid}/downstream")
    print(f"Device 2 (Sub) connected and subscribed to bridge/{guid}/downstream")

def on_message(client, userdata, msg):
    print("Device 2 received payload:")
    print(msg.payload.decode())
    messages_received.append(True)

sub_client = mqtt.Client(client_id="device_2", protocol=mqtt.MQTTv311)
sub_client.on_connect = on_connect
sub_client.on_message = on_message
sub_client.connect("localhost", 1883, 60)
sub_client.loop_start()

time.sleep(1)

pub_client = mqtt.Client(client_id="device_1", protocol=mqtt.MQTTv311)
pub_client.connect("localhost", 1883, 60)
payload = {
    "type": "notification",
    "version": 1,
    "metadata": {
        "device_id": "d1",
        "device_name": "Device 1",
        "guid": guid,
        "timestamp": int(time.time()*1000)
    },
    "data": {
        "app_package": "com.test.app",
        "title": "Alert",
        "body": "Python pub/sub test"
    }
}
pub_client.publish(f"bridge/{guid}/upstream", json.dumps(payload), qos=1)
print(f"Device 1 published payload to bridge/{guid}/upstream")

time.sleep(2)
sub_client.loop_stop()
pub_client.disconnect()

if not messages_received:
    print("TEST FAILED")
    sys.exit(1)
else:
    print("TEST PASSED")
    sys.exit(0)
