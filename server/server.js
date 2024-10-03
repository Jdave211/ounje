import express from "express";
import bodyParser from "body-parser";
import axios from "axios";
import dotenv from "dotenv";
import mongoose from "mongoose";
import cors from "cors";

import api_router from "./api/index.js";

dotenv.config();

const app = express();
app.use(bodyParser.json({ limit: "50mb" }));
app.use(cors());

app.use(api_router);
app.get("/", (req, res) => {
  res.json({ message: "Hello from server" });
});
const PORT = process.env.PORT || 8080;

mongoose.connect(process.env.MONGO_DB_URI);

const db = mongoose.connection;

db.on("error", console.error.bind(console, "connection error!"));
db.once("open", async () => {
  app.listen(PORT, function () {
    console.log(`Server listening at http://localhost:${PORT}`);
  });
});
