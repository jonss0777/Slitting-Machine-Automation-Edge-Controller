import time
import threading
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import create_engine, Column, Integer, Boolean, DateTime, String
from sqlalchemy.orm import declarative_base, sessionmaker, Session
from pymodbus.client import ModbusTcpClient

# ==========================================
# 1. Database Setup
# ==========================================
DB_URL = "postgresql+psycopg2://postgres:%40Coop2321r@localhost:5432/automation_db"

engine = create_engine(DB_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


class PLCState(Base):
    __tablename__ = "plc_states"

    id = Column(Integer, primary_key=True, index=True)
    timestamp = Column(
        DateTime(timezone=True),
        default=lambda: datetime.now(timezone.utc),
        index=True,
    )
    
    # Original PLC state attributes
    state = Column(Integer, nullable=False, default=1)
    auto_step = Column(Integer, nullable=False, default=0)
    successful_runs = Column(Integer, nullable=False, default=0)
    failed_runs = Column(Integer, nullable=False, default=0)
    connected = Column(Boolean, nullable=False, default=False)

    # Connection metadata
    esp_ip = Column(String, nullable=False)
    port = Column(Integer, nullable=False)
    unit_id = Column(Integer, nullable=False)


Base.metadata.create_all(bind=engine)


# ==========================================
# 2. PyModbus Poller Class
# ==========================================
class OpenPLCPoller:
    def __init__(
        self,
        esp32_ip: str,
        port: int = 502,
        poll_interval: float = 0.5,
        unit_id: int = 1,
    ):
        self.esp32_ip = esp32_ip
        self.port = port
        self.poll_interval = poll_interval
        self.unit_id = unit_id
        self.running = False
        self.thread: Optional[threading.Thread] = None

    def start(self):
        self.running = True
        self.thread = threading.Thread(target=self._poll_loop, daemon=True)
        self.thread.start()

    def stop(self):
        self.running = False

    def _poll_loop(self):
        client = ModbusTcpClient(self.esp32_ip, port=self.port)

        while self.running:
            is_connected = client.is_socket_open()
            if not is_connected:
                is_connected = client.connect()

            if is_connected:
                try:
                  
                
                    # Read State (%MW0) and AutoStep (%MW1)
                    # (Reading from address 32 assuming base state variables, count=2)
                    rr_base = client.read_holding_registers(address=32, count=2, device_id=1)
                                    
                    # Read Counters: %MD0 (Reg 0,1) and %MD2 (Reg 2,3) -> Total 4 registers
                    # OpenPLC maps %MD words to the lower holding register boundary.
                    rr_counters = client.read_holding_registers(address=56, count=6, device_id=1)

                    if  not rr_base.isError() and  not rr_counters.isError():
                                              
                        WORD_ORDER  = "big"
                        # rr_counters.registers[0:2] = Registers 36 & 37 (%MD2)
                        # rr_counters.registers[4:6] = Registers 40 & 41 (%MD4)
                        success_regs = rr_counters.registers[0:2]
                        failed_regs  = rr_counters.registers[4:6]
                                                
                       
                        #registers = holding_res.registers
                        record = PLCState(
                            state=rr_base.registers[0],
                            auto_step=rr_base.registers[1],
                            successful_runs=client.convert_from_registers( 
                            success_regs, data_type=client.DATATYPE.INT32, word_order=WORD_ORDER
                            ),
                            failed_runs=client.convert_from_registers( 
                                failed_regs,
                                data_type=client.DATATYPE.INT32,
                                word_order=WORD_ORDER
                            ),
                            connected=True,
                            esp_ip=self.esp32_ip,
                            port=self.port,
                            unit_id=self.unit_id,
                        )
                    else:
                        # Communication error during read
                        record = PLCState(
                            state=0,
                            auto_step=0,
                            successful_runs=0,
                            failed_runs=0,
                            connected=False,
                            esp_ip=self.esp32_ip,
                            port=self.port,
                            unit_id=self.unit_id,
                        )

                except Exception as e:
                    print(f"[Modbus Exception] Error reading PLC: {e}")
                    record = PLCState(
                        state=0,
                        auto_step=0,
                        successful_runs=0,
                        failed_runs=0,
                        connected=False,
                        esp_ip=self.esp32_ip,
                        port=self.port,
                        unit_id=self.unit_id,
                    )
            else:
                # Unable to connect to ESP32 socket
                record = PLCState(
                    state=0,
                    auto_step=0,
                    successful_runs=0,
                    failed_runs=0,
                    connected=False,
                    esp_ip=self.esp32_ip,
                    port=self.port,
                    unit_id=self.unit_id,
                )

            # Persist state to PostgreSQL database
            db = SessionLocal()
            try:
                db.add(record)
                db.commit()
            except Exception as e:
                db.rollback()
                print(f"[DB Error] Failed to write state: {e}")
            finally:
                db.close()

            time.sleep(self.poll_interval)

        client.close()


# Configuration for ESP32 OpenPLC
ESP32_IP = "192.168.0.173"
MODBUS_PORT = 502
UNIT_ID = 1

plc_poller = OpenPLCPoller(
    esp32_ip=ESP32_IP,
    port=MODBUS_PORT,
    unit_id=UNIT_ID,
    # poll_interval=0.5,
    poll_interval=3,
)


# ==========================================
# 3. FastAPI Lifecycle & Endpoints
# ==========================================
app = FastAPI(title="ESP32 OpenPLC Edge Controller")


@app.on_event("startup")
def startup_event():
    plc_poller.start()


@app.on_event("shutdown")
def shutdown_event():
    plc_poller.stop()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


class PLCStateResponse(BaseModel):
    id: int
    timestamp: datetime
    state: int
    auto_step: int
    successful_runs: int
    failed_runs: int
    connected: bool
    esp_ip: str
    port: int
    unit_id: int

    class Config:
        from_attributes = True


@app.get("/api/plc/state", response_model=PLCStateResponse)
def get_latest_plc_state(db: Session = Depends(get_db)):
    """
    Returns the most recent PLC state reading from PostgreSQL.
    """
    latest_state = (
        db.query(PLCState).order_by(PLCState.timestamp.desc()).first()
    )

    if not latest_state:
        raise HTTPException(
            status_code=404,
            detail="No PLC state records found in database.",
        )

    return latest_state