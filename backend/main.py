from fastapi import FastAPI, HTTPException
from pydantic import BaseModel


app = FastAPI(title="Calculadora API", version="1.0.0")


class Calculation(BaseModel):
    a: float
    b: float
    op: str


@app.get("/health")
def health():
    return {"status": "ok", "version": "1.0.0"}


@app.post("/calculate")
def calculate(payload: Calculation):
    if payload.op == "add":
        result = payload.a + payload.b
    elif payload.op == "sub":
        result = payload.a - payload.b
    elif payload.op == "mul":
        result = payload.a * payload.b
    elif payload.op == "div":
        if payload.b == 0:
            raise HTTPException(status_code=400, detail="division by zero")
        result = payload.a / payload.b
    else:
        raise HTTPException(status_code=400, detail="unsupported operation")

    return {"result": result}


@app.get("/boom")
def boom():
    raise HTTPException(status_code=500, detail="boom")
