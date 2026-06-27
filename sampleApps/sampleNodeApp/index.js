const fs = require('fs');

// Check for contract query
if (process.argv.includes('--show-spec')) {
    console.log('REQUIRED_PARAMETERS=multiplication_factor');
    console.log('REQUIRED_SECRETS=');
    process.exit(0);
}

const express = require('express');
const { MongoClient } = require('mongodb');

const app = express();
const port = process.env.PORT || 3000;
const appDomain = process.env.APP_DOMAIN || 'localhost';
const multiplicationFactorEnv = process.env.multiplication_factor;

// Read MongoDB connection string from container secret or fallback to env
let mongoUri;
const secretPath = '/run/secrets/MONGO_URI';

if (fs.existsSync(secretPath)) {
    console.log(`Loading MongoDB URI from container secret: ${secretPath}`);
    mongoUri = fs.readFileSync(secretPath, 'utf8').trim();
} else if (process.env.MONGO_URI) {
    console.log('Loading MongoDB URI from environment variable');
    mongoUri = process.env.MONGO_URI;
} else {
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
        const dbNameMatch = mongoUri.match(/\/([a-zA-Z0-9_-]+)(?:\?|$)/);
        const dbName = dbNameMatch ? dbNameMatch[1] : 'sample_node_db';
        db = dbClient.db(dbName);
        console.log(`Using database: ${dbName}`);

        // Persist the multiplication factor in collection "multiplication_factor_correct_persistency_proof"
        const collection = db.collection('multiplication_factor_correct_persistency_proof');
        
        // Clear existing proof documents
        await collection.deleteMany({});
        
        const parsedFactor = multiplicationFactorEnv ? parseFloat(multiplicationFactorEnv) : 1;
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
