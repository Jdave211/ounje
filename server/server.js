import express from "express";
import bodyParser from "body-parser";
import axios from "axios";
import dotenv from "dotenv";
import cors from "cors";

import api_router from "./api/index.js";
import { startRecipeFineTunePolling } from "./lib/recipe-model-registry.js";

dotenv.config({ path: new URL("./.env", import.meta.url).pathname });

const app = express();
app.use(bodyParser.json({ limit: "50mb" }));
app.use(cors());

app.use(api_router);
app.get("/", (req, res) => {
  res.json({ message: "Hello from server" });
});
const PORT = process.env.PORT || 8080;
const HOST = process.env.HOST || "0.0.0.0";
startRecipeFineTunePolling();
app.listen(PORT, HOST, function () {
  console.log(`Server listening at http://${HOST}:${PORT}`);
});
