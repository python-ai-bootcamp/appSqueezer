const fs = require('fs');

// Check for contract query
if (process.argv.includes('--show-spec')) {
    console.log('REQUIRED_PARAMETERS=multiplication_factor');
    console.log('REQUIRED_SECRETS=');
    process.exit(0);
}

const path = require('path');

function getSecretOrEnv(secretName, envFallbackName) {
    const secretPath = path.join('/run/secrets', secretName);
    try {
        if (fs.existsSync(secretPath) && fs.statSync(secretPath).isFile()) {
            console.log(`Loading ${secretName} from container secret: ${secretPath}`);
            return fs.readFileSync(secretPath, 'utf8').trim();
        }
    } catch (err) {
        // Ignore and fallback
    }
    const fallbackVal = process.env[envFallbackName] || process.env[secretName] || '';
    if (fallbackVal) {
        console.log(`Loading ${secretName} from environment variable`);
    }
    return fallbackVal;
}

const express = require('express');
const { MongoClient } = require('mongodb');

const app = express();
const port = process.env.PORT || 3000;
const appDomain = process.env.APP_DOMAIN || 'localhost';
const multiplicationFactorEnv = process.env.multiplication_factor;

// Read MongoDB connection string from container secret or fallback to env
const mongoUri = getSecretOrEnv('MONGO_URI', 'MONGO_URI');

if (!mongoUri) {
    console.error('Error: Neither /run/secrets/MONGO_URI nor MONGO_URI env variable is set.');
    process.exit(1);
}

let dbClient;
let db;

async function initDbAndApp() {
    try {
        dbClient = new MongoClient(mongoUri);
        await dbClient.connect();
        console.log('Successfully connected to MongoDB.');

        // Extract database name from connection URI or default to 'sample_node_db'
        // A standard Mongo URI contains the database name after the slash before query params:
        // mongodb://user:pass@host:port/dbname?authSource=admin
        let dbName = 'sample_node_db';
        try {
            const parsedUri = new URL(mongoUri);
            const pathDb = parsedUri.pathname.replace(/^\//, '');
            if (pathDb) {
                dbName = pathDb;
            }
        } catch (e) {
            // Regex fallback for non-standard connection strings
            const dbNameMatch = mongoUri.match(/\/([a-zA-Z0-9_-]+)(?:\?|$)/);
            if (dbNameMatch) {
                dbName = dbNameMatch[1];
            }
        }
        db = dbClient.db(dbName);
        console.log(`Using database: ${dbName}`);

        // Persist the multiplication factor in collection "multiplication_factor_correct_persistency_proof"
        const collection = db.collection('multiplication_factor_correct_persistency_proof');
        
        // Clear existing proof documents
        await collection.deleteMany({});
        
        let parsedFactor = multiplicationFactorEnv ? parseFloat(multiplicationFactorEnv) : 1;
        if (isNaN(parsedFactor)) {
            console.warn('Warning: Invalid multiplication_factor parameter. Falling back to 1.');
            parsedFactor = 1;
        }
        await collection.insertOne({ multiplication_factor: parsedFactor });
        console.log(`Persisted proof document with multiplication_factor = ${parsedFactor}`);

        // Start listening
        app.listen(port, () => {
            console.log(`Server running at http://${appDomain}:${port} inside container.`);
        });
    } catch (err) {
        console.error('Failed to initialize database or start application:', err);
        process.exit(1);
    }
}

// Routes
app.get('/multiply/:value', async (req, res) => {
    try {
        const inputVal = parseFloat(req.params.value);
        if (isNaN(inputVal)) {
            return res.status(400).json({ error: 'Value parameter must be a number.' });
        }

        // Fetch factor from DB
        const collection = db.collection('multiplication_factor_correct_persistency_proof');
        const proofDoc = await collection.findOne({});
        
        if (!proofDoc) {
            return res.status(500).json({ error: 'No multiplication factor found in database.' });
        }

        const factor = proofDoc.multiplication_factor;
        const result = factor * inputVal;

        res.json({
            app: 'Node.js Sample App',
            domain: appDomain,
            factor: factor,
            input: inputVal,
            result: result
        });
    } catch (err) {
        console.error('Error handling /multiply request:', err);
        res.status(500).json({ error: 'Internal server error.' });
    }
});

// Root path diagnostic route
app.get('/', (req, res) => {
    res.json({
        status: 'online',
        app: 'Node.js Sample App',
        domain: appDomain,
        port: port,
        multiplication_factor_set: !!multiplicationFactorEnv
    });
});

initDbAndApp();
