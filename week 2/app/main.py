"""
Secure Python Health API
"""

from fastapi import FastAPI
from fastapi.responses import JSONResponse
import logging

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Health API",
    description="Minimal health check API with security-first principles",
    version="1.0.0"
)


@app.get("/health", tags=["Health"])
async def health_check():
    """
    Health check endpoint
    Returns: {"status": "healthy", "version": "1.0.0"}
    """
    logger.info("Health check requested")
    return JSONResponse(
        status_code=200,
        content={
            "status": "healthy",
            "version": "1.0.0"
        }
    )


@app.get("/", tags=["Root"])
async def root():
    """Root endpoint - redirects to /health"""
    return JSONResponse(
        status_code=200,
        content={"message": "Health API - visit /health for status"}
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        log_level="info"
    )
