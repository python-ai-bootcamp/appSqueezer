import os
import re
import sys

# Check for contract query
if '--show-spec' in sys.argv:
    print('REQUIRED_PARAMETERS=multiplication_factor')
    print('REQUIRED_SECRETS=')
    sys.exit(0)

def get_secret_or_env(secret_name: str, env_fallback_name: str) -> str:
    secret_path = os.path.join('/run/secrets', secret_name)
    try:
        if os.path.isfile(secret_path):
            print(f"Loading {secret_name} from container secret: {secret_path}")
            with open(secret_path, 'r', encoding='utf-8') as f:
                return f.read().strip()
    except Exception:
        pass
    fallback_val = os.getenv(env_fallback_name) or os.getenv(secret_name) or ''
    if fallback_val:
        print(f"Loading {secret_name} from environment variable")
    return fallback_val

from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from pymongo import MongoClient

# Setup configurations
port = int(os.getenv("PORT", 3000))
app_domain = os.getenv("APP_DOMAIN", "localhost")
multiplication_factor_env = os.getenv("multiplication_factor")

# Retrieve MongoDB connection string
mongo_uri = get_secret_or_env('MONGO_URI', 'MONGO_URI')
if not mongo_uri:
    print("Error: Neither /run/secrets/MONGO_URI nor MONGO_URI env variable is set.", file=sys.stderr)
    sys.exit(1)

# Extract database name from connection URI
try:
    from urllib.parse import urlparse
    parsed_uri = urlparse(mongo_uri)
    path_db = parsed_uri.path.lstrip('/')
    if path_db:
        db_name = path_db
    else:
        db_name = "sample_python_db"
except Exception:
    try:
        db_name_match = re.search(r'/([a-zA-Z0-9_-]+)(?:\?|$)', mongo_uri)
        db_name = db_name_match.group(1) if db_name_match else "sample_python_db"
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
        
        try:
            factor = float(multiplication_factor_env) if multiplication_factor_env else 1.0
        except ValueError:
            print("Warning: Invalid multiplication_factor parameter. Falling back to 1.0", file=sys.stderr)
            factor = 1.0
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
def multiply(value: float):
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

