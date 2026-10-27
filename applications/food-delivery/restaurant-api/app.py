from flask import Flask, jsonify
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST
app=Flask(__name__)
requests=Counter("restaurant_api_requests_total","Restaurant API requests",["endpoint"])
restaurant={"id":"localbite-kitchen","name":"LocalBite Kitchen","description":"South Indian favourites for this demo."}
items=[{"id":"masala-dosa","name":"Masala Dosa","price":90},{"id":"idli-vada","name":"Idli Vada","price":60},{"id":"paneer-roll","name":"Paneer Roll","price":120},{"id":"filter-coffee","name":"Filter Coffee","price":35}]
@app.get("/healthz")
def health(): return jsonify(status="ok")
@app.get("/restaurants")
def restaurants():
    requests.labels("/restaurants").inc()
    return jsonify(restaurant=restaurant,items=items)
@app.get("/metrics")
def metrics(): return generate_latest(),200,{"Content-Type":CONTENT_TYPE_LATEST}
