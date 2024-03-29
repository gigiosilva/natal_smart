import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:mqtt_client/mqtt_client.dart' as mqtt;
import 'package:natal_smart/components/item_smart.dart';
import 'package:natal_smart/screens/novo.dart';
import 'package:natal_smart/services/toast.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:natal_smart/models/item_smart.dart';

class MyHomePage extends StatefulWidget {
  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String broker = 'test.mosquitto.org';
  int port = 1883;
  String username = '';
  String password = '';
  String clientIdentifier = 'gigio';

  List<Item> _itemsSmart = List();

  mqtt.MqttClient client;
  mqtt.MqttConnectionState connectionState;
  StreamSubscription subscription;

  @override
  void initState() {
    _loadData();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: CustomScrollView(
        semanticChildCount: _itemsSmart.length,
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: Text('Smart Home'),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              child: Icon(
                CupertinoIcons.plus_circled,
                semanticLabel: 'Add',
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  CupertinoPageRoute(builder: (context) => NovoPage()),
                ).then(
                  (itemRecebido) => _saveItem(itemRecebido),
                );
              },
            ),
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              child: Icon(
                CupertinoIcons.refresh,
                semanticLabel: 'Reload',
              ),
              onPressed: _refreshConnection,
            ),
          ),
          SliverSafeArea(
            top: false,
            minimum: EdgeInsets.only(top: 8),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = _itemsSmart[index];
                return ItemSmart(
                  item: item,
                  index: index,
                  status: item.status,
                  deleted: _deleteItem,
                  onChange: _sendMessage,
                );
              }, childCount: _itemsSmart.length),
            ),
          ),
        ],
      ),
    );
  }

  void _refreshConnection() {
    _disconnect();
    _connect();
  }

  void _loadData() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      List<String> savedList = (prefs.getStringList('items') ?? []);
      List list = json.decode(savedList.toString()) as List;
      List<Item> itemsSmart = list.map((i) => Item.fromJson(i)).toList();

      _itemsSmart = itemsSmart;

      _connect();
    });
  }

  void _saveItem(Item itemSmart) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (itemSmart != null) {
      setState(() => _itemsSmart.add(itemSmart));
      _subscribeToTopic(itemSmart.codigo);
      List<String> stringList = _itemsSmart.map((i) => json.encode(i)).toList();
      prefs.setStringList('items', stringList);
    }
  }

  void _deleteItem(index) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();

    setState(() {
      Item removedItem = _itemsSmart.removeAt(index);
      List<String> stringList = _itemsSmart.map((i) => json.encode(i)).toList();
      prefs.setStringList('items', stringList);
      client.unsubscribe(removedItem.codigo);
    });
  }

  void _updateItem(message, topicName) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    _itemsSmart.forEach((item) {
      if (item.codigo == topicName) {
        item.status = message == item.valueOn ? true : false;
      }
    });

    List<String> stringList = _itemsSmart.map((i) => json.encode(i)).toList();
    prefs.setStringList('items', stringList);
  }

  void _connect() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();

    broker = (prefs.getString('hostname') ?? broker);
    port = (prefs.getInt('port') ?? port);
    clientIdentifier = (prefs.getString('clientID') ?? clientIdentifier);
    username = (prefs.getString('username') ?? username);
    password = (prefs.getString('password') ?? password);

    client = mqtt.MqttClient(broker, clientIdentifier);
    client.port = port;
    client.logging(on: true);
    client.keepAlivePeriod = 30;
    client.onDisconnected = _onDisconnected;
    client.onConnected = _onConnected;

    final mqtt.MqttConnectMessage connMess = mqtt.MqttConnectMessage()
        .withClientIdentifier(clientIdentifier)
        .keepAliveFor(30)
        .withWillQos(mqtt.MqttQos.atMostOnce);

    client.connectionMessage = connMess;

    try {
      if (username == '' && password == '') {
        await client.connect();
      } else {
        await client.connect(username, password);
      }
    } catch (e) {
      print(e);
      ToastService.showNegative(msg: e.toString(), duration: 5);
      _disconnect();
    }
  }

  void _onConnected() {
    connectionState = client.connectionStatus.state;
    ToastService.showPositive(msg: 'Connected to $broker');
    subscription = client.updates.listen(_onMessage);

    _itemsSmart.forEach((item) {
      _subscribeToTopic(item.codigo);
    });
  }

  void _subscribeToTopic(String topic) {
    if (connectionState == mqtt.MqttConnectionState.connected) {
      client.subscribe(topic, mqtt.MqttQos.exactlyOnce);
      debugPrint('Subscribed to $topic');
    } else {
      debugPrint('Error Subscribing $connectionState');
      ToastService.showNegative(
          msg: 'Error Subscribing $connectionState', duration: 3);
    }
  }

  void _onMessage(List<mqtt.MqttReceivedMessage> event) {
    final mqtt.MqttPublishMessage recMess =
        event[0].payload as mqtt.MqttPublishMessage;
    final String message =
        mqtt.MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

    setState(() {
      _updateItem(message, recMess.payload.variableHeader.topicName);
    });
  }

  void _disconnect() async {
    if (client != null) client.disconnect();
  }

  void _onDisconnected() {
    subscription.cancel();
    connectionState = null;
    client = null;
    ToastService.showNegative(msg: 'Disconnected');
  }

  void _sendMessage(topic, value) {
    final mqtt.MqttClientPayloadBuilder builder =
        mqtt.MqttClientPayloadBuilder();

    builder.addString(value);

    if (client != null) {
      client.publishMessage(topic, mqtt.MqttQos.atLeastOnce, builder.payload,
          retain: true);
    } else {
      _connect();
      client.publishMessage(topic, mqtt.MqttQos.atLeastOnce, builder.payload,
          retain: true);
      ToastService.showPositive(msg: 'Reconnecting..');
    }
  }
}
