import json,os,uuid
from datetime import datetime,timezone
import redis
from flask import Flask,jsonify,request
from prometheus_client import Counter,generate_latest
app=Flask(__name__)
r=redis.Redis(host=os.getenv("REDIS_HOST","redis"),port=int(os.getenv("REDIS_PORT","6379")),decode_responses=True,socket_connect_timeout=2,socket_timeout=2)
requests=Counter("order_api_requests_total","Order API requests",["endpoint"])
menu={"masala-dosa":{"name":"Masala Dosa","price":90},"idli-vada":{"name":"Idli Vada","price":60},"paneer-roll":{"name":"Paneer Roll","price":120},"filter-coffee":{"name":"Filter Coffee","price":35}}
@app.get("/healthz")
def health():
    try: r.ping(); return jsonify(status="ok",redis="ok")
    except redis.RedisError: return jsonify(status="degraded",redis="unavailable"),503
@app.get("/orders")
def list_orders():
    requests.labels("/orders").inc()
    try: return jsonify(orders=[json.loads(x) for x in r.lrange("orders:recent",0,19)])
    except redis.RedisError: return jsonify(error="Order store temporarily unavailable"),503
@app.post("/orders")
def create_order():
    requests.labels("/orders").inc()
    body=request.get_json(silent=True) or {}; customer=str(body.get("customer","")).strip()[:80]; items=body.get("items")
    if not customer: return jsonify(error="customer is required"),400
    if not isinstance(items,list) or not items: return jsonify(error="items must be a non-empty list"),400
    normalized=[]; total=0
    for item in items:
        if not isinstance(item,dict): return jsonify(error="each item must be an object"),400
        item_id=item.get("id")
        try: quantity=int(item.get("quantity",0))
        except (ValueError,TypeError): return jsonify(error="quantity must be an integer"),400
        if item_id not in menu or quantity<1 or quantity>20: return jsonify(error="invalid item or quantity (1-20)"),400
        product=menu[item_id]; line=product["price"]*quantity; total+=line
        normalized.append({"id":item_id,"name":product["name"],"quantity":quantity,"unit_price":product["price"],"line_total":line})
    order={"id":str(uuid.uuid4()),"customer":customer,"items":normalized,"total":total,"status":"RECEIVED","created_at":datetime.now(timezone.utc).isoformat()}
    try:
        r.lpush("orders:recent",json.dumps(order)); r.ltrim("orders:recent",0,99)
        return jsonify(order=order),201
    except redis.RedisError: return jsonify(error="Order store temporarily unavailable"),503
@app.get("/metrics")
def metrics(): return generate_latest(),200,{"Content-Type":"text/plain; version=0.0.4; charset=utf-8"}
