import os
import sys

# Check for contract query
if '--show-spec' in sys.argv:
    print('REQUIRED_PARAMETERS=multiplication_factor')
    print('REQUIRED_SECRETS=')
    sys.exit(0)

from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from pymongo import MongoClient

# Setup configurations
port = int(os.getenv("PORT", 3000))
app_domain = os.getenv("APP_DOMAIN", "localhost")
multiplication_factor_env = os.getenv("multiplication_factor")

# Retrieve MongoDB connection string
secret_path = "/run/secrets/MONGO_URI"
if os.path.exists(secret_path):
    print(f"Loading MongoDB URI from container secret: {secret_path}")
    with open(secret_path, "r", encoding="utf-8") as f:
        mongo_uri = f.read().strip()
elif os.getenv("MONGO_URI"):
    print("Loading MongoDB URI from environment variable")
    mongo_uri = os.getenv("MONGO_URI")
else:
    print("Error: Neither /run/secrets/MONGO_URI nor MONGO_URI env variable is set.", file=sys.stderr)
    sys.exit(1)

# Extract database name from connection URI
try:
    temp_uri = mongo_uri.split("?")[0]
    db_name = temp_uri.split("/")[-1]
    if not db_name or db_name.startswith("mongodb"):
        db_name = "sample_python_db"
except Exception:
    db_name = "sample_python_db"

db_client = None
db = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global db_client, db
    try:
        db_client = MongoClient(mongo_uri)
        # Force a connection check to verify authentication
        db_client.admin.command('ping')
        print("Successfully connected to MongoDB.")
        
        db = db_client[db_name]
        print(f"Using database: {db_name}")
        
        # Persist the multiplication factor in collection
        collection = db["multiplication_factor_correct_persistency_proof"]
        
        # Clear existing proof documents
        collection.delete_many({})
        
        factor = float(multiplication_factor_env) if multiplication_factor_env else 1.0
        collection.insert_one({"multiplication_factor": factor})
        print(f"Persisted proof document with multiplication_factor = {factor}")
        
        yield
    except Exception as e:
        print(f"Failed to initialize database or start application: {e}", file=sys.stderr)
        raise e
    finally:
        if db_client:
            db_client.close()
            print("MongoDB connection closed.")

app = FastAPI(lifespan=lifespan)

@app.get("/multiply/{value}")
async def multiply(value: float):
    if db is None:
        raise HTTPException(status_code=500, detail="Database connection is not initialized.")
    try:
        collection = db["multiplication_factor_correct_persistency_proof"]
        proof_doc = collection.find_one({})
        if not proof_doc:
            raise HTTPException(status_code=500, detail="No multiplication factor found in database.")
            
        factor = proof_doc["multiplication_factor"]
        result = factor * value
        
        return {
            "app": "Python Sample App",
            "domain": app_domain,
            "factor": factor,
            "input": value,
            "result": result
        }
    except Exception as e:
        print(f"Error handling /multiply request: {e}", file=sys.stderr)
        raise HTTPException(status_code=500, detail="Internal server error.")

@app.get("/")
async def root():
    return {
        "status": "online",
        "app": "Python Sample App",
        "domain": app_domain,
        "port": port,
        "multiplication_factor_set": multiplication_factor_env is not None
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=port)

