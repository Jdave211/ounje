// import { createLogger, format, transports } from "winston";
// import { Console } from "winston/lib/winston/transports";
// const { combine, timestamp, printf, colorize } = format;

// const customFormat = printf(({ level, message, timestamp }) => {
//   return `${timestamp} ${level}: ${message}`;
// });

// export const logger = createLogger({
//   level: process.env.NODE_ENV === "development" ? "debug" : "info",
//   format: combine(
//     timestamp({ format: "YYYY-MM-DD HH:mm:ss" }),
//     colorize(),
//     customFormat
//   ),
//   transports: [new Console()],
// });
