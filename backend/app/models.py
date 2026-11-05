from datetime import datetime, timezone
from sqlalchemy import String, ForeignKey, Integer, JSON, UniqueConstraint, Text, BigInteger, Index, text, LargeBinary
from sqlalchemy.orm import Mapped, mapped_column
from .db import Base

DISCARDED = 'Descartada'
ACTIVE_DPS = "status IS NULL OR status <> 'Descartada'"

def now():
    return datetime.now(timezone.utc).isoformat()
class User(Base):
    __tablename__ = 'users'
    id: Mapped[int] = mapped_column(primary_key=True)
    username: Mapped[str] = mapped_column(String(80), unique=True)
    password_hash: Mapped[str] = mapped_column(Text)
    role: Mapped[str] = mapped_column(String(20), default='operator')
    active: Mapped[bool] = mapped_column(default=True)
class LoginSession(Base):
    __tablename__ = 'sessions'
    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey('users.id'))
    expires: Mapped[str] = mapped_column(String(40))
class Company(Base):
    __tablename__ = 'companies'
    id: Mapped[int] = mapped_column(primary_key=True)
    cnpj: Mapped[str] = mapped_column(String(14), unique=True)
    name: Mapped[str] = mapped_column(String(200))
    config: Mapped[dict] = mapped_column(JSON, default=dict)
    revision: Mapped[int] = mapped_column(default=1)
class Access(Base):
    __tablename__ = 'user_companies'
    user_id: Mapped[int] = mapped_column(ForeignKey('users.id'), primary_key=True)
    company_id: Mapped[int] = mapped_column(ForeignKey('companies.id'), primary_key=True)
class Customer(Base):
    __tablename__ = 'customers'
    __table_args__ = (UniqueConstraint('company_id', 'document'),)
    id: Mapped[int] = mapped_column(primary_key=True)
    company_id: Mapped[int] = mapped_column(ForeignKey('companies.id'))
    document: Mapped[str] = mapped_column(String(14))
    name: Mapped[str] = mapped_column(String(200))
    details: Mapped[dict] = mapped_column(JSON, default=dict)
class Service(Base):
    __tablename__ = 'services'
    id: Mapped[int] = mapped_column(primary_key=True)
    company_id: Mapped[int] = mapped_column(ForeignKey('companies.id'))
    name: Mapped[str] = mapped_column(String(200))
    config: Mapped[dict] = mapped_column(JSON, default=dict)
    revision: Mapped[int] = mapped_column(default=1)
class Batch(Base):
    __tablename__ = 'batches'
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(200))
    owner_id: Mapped[int] = mapped_column(ForeignKey('users.id'))
    created_at: Mapped[str] = mapped_column(default=now)
    revision: Mapped[int] = mapped_column(default=1)
    status: Mapped[str] = mapped_column(String(40), default='Aguardando validação')
    approval_digest: Mapped[str | None] = mapped_column(String(64), nullable=True)
    approved_by: Mapped[int | None] = mapped_column(ForeignKey('users.id'), nullable=True)
class Draft(Base):
    __tablename__ = 'drafts'
    id: Mapped[int] = mapped_column(primary_key=True)
    batch_id: Mapped[int] = mapped_column(ForeignKey('batches.id'))
    company_id: Mapped[int | None] = mapped_column(ForeignKey('companies.id'), nullable=True)
    line: Mapped[int] = mapped_column()
    raw: Mapped[dict] = mapped_column(JSON)
    errors: Mapped[list] = mapped_column(JSON, default=list)
    amount_cents: Mapped[int] = mapped_column(default=0)
    fingerprint: Mapped[str | None] = mapped_column(String(64), unique=True, nullable=True)
    status: Mapped[str] = mapped_column(String(60), default='Rascunho')
    company_revision: Mapped[int | None] = mapped_column(nullable=True)
    snapshot: Mapped[dict] = mapped_column(JSON, default=dict)
class Job(Base):
    __tablename__ = 'jobs'
    id: Mapped[int] = mapped_column(primary_key=True)
    draft_id: Mapped[int] = mapped_column(ForeignKey('drafts.id'), unique=True)
    status: Mapped[str] = mapped_column(String(40), default='Na fila')
    mode: Mapped[str] = mapped_column(String(20), default='simulation')
    result: Mapped[dict] = mapped_column(JSON, default=dict)
class DpsSeries(Base):
    """Central DPS numbering per issuer/environment/series. Numbers only move forward and are never reused."""
    __tablename__ = 'dps_series'
    __table_args__ = (UniqueConstraint('company_id', 'environment', 'series'),)
    id: Mapped[int] = mapped_column(primary_key=True)
    company_id: Mapped[int] = mapped_column(ForeignKey('companies.id'))
    environment: Mapped[str] = mapped_column(String(1))
    series: Mapped[str] = mapped_column(String(5))
    next_number: Mapped[int] = mapped_column(BigInteger)
    revision: Mapped[int] = mapped_column(default=1)
class DPS(Base):
    __tablename__ = 'dps'
    # A draft may keep discarded reservations, but only one active (non-discarded) DPS. Numbers are never reused.
    __table_args__ = (UniqueConstraint('company_id', 'environment', 'series', 'number', name='uq_dps_number'),
                      Index('uq_dps_active_draft', 'draft_id', unique=True, sqlite_where=text(ACTIVE_DPS), postgresql_where=text(ACTIVE_DPS)))
    id: Mapped[int] = mapped_column(primary_key=True)
    draft_id: Mapped[int] = mapped_column(ForeignKey('drafts.id'))
    environment: Mapped[str] = mapped_column(String(20))
    identifier: Mapped[str] = mapped_column(String(80), unique=True)
    xml_path: Mapped[str | None] = mapped_column(nullable=True)
    xml_sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # Columns added in 0.6.0 (nullable for an additive migration of the existing table).
    company_id: Mapped[int | None] = mapped_column(ForeignKey('companies.id'), nullable=True)
    series: Mapped[str | None] = mapped_column(String(5), nullable=True)
    number: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    status: Mapped[str | None] = mapped_column(String(40), nullable=True)
    issued_at: Mapped[str | None] = mapped_column(String(40), nullable=True)
    xml: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[str | None] = mapped_column(String(40), nullable=True, default=now)
    created_by: Mapped[int | None] = mapped_column(ForeignKey('users.id'), nullable=True)
    # Columns added in 0.6.1: discarding keeps the row and its number; it only releases the draft.
    discarded_at: Mapped[str | None] = mapped_column(String(40), nullable=True)
    discarded_by: Mapped[int | None] = mapped_column(ForeignKey('users.id'), nullable=True)
    discard_reason: Mapped[str | None] = mapped_column(String(500), nullable=True)
    # Columns added in 0.9.0: result reported by the local connector (signing and submission happen on the PC).
    access_key: Mapped[str | None] = mapped_column(String(60), nullable=True)
    nfse_xml: Mapped[str | None] = mapped_column(Text, nullable=True)
    result: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    result_at: Mapped[str | None] = mapped_column(String(40), nullable=True)
    # Columns added in 0.9.1: official DANFSe (PDF from the ADN) fetched by the connector with the certificate.
    danfse_pdf: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    danfse_at: Mapped[str | None] = mapped_column(String(40), nullable=True)
    danfse_error: Mapped[str | None] = mapped_column(String(60), nullable=True)
class ConnectorTicket(Base):
    """Short-lived, single-purpose credential carried by the triade-nfse:// link. Only its SHA-256 is stored."""
    __tablename__ = 'connector_tickets'
    id: Mapped[int] = mapped_column(primary_key=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    user_id: Mapped[int] = mapped_column(ForeignKey('users.id'))
    dps_ids: Mapped[list] = mapped_column(JSON, default=list)
    created_at: Mapped[str] = mapped_column(String(40), default=now)
    expires_at: Mapped[str] = mapped_column(String(40))
    revoked: Mapped[bool] = mapped_column(default=False)
class NFSe(Base):
    __tablename__ = 'nfse'
    id: Mapped[int] = mapped_column(primary_key=True)
    dps_id: Mapped[int] = mapped_column(ForeignKey('dps.id'), unique=True)
    access_key: Mapped[str] = mapped_column(String(60), unique=True)
    protocol: Mapped[str | None] = mapped_column(nullable=True)
    xml_path: Mapped[str] = mapped_column()
    danfse_path: Mapped[str | None] = mapped_column(nullable=True)
    xml_sha256: Mapped[str] = mapped_column(String(64))
class Audit(Base):
    __tablename__ = 'audit'
    id: Mapped[int] = mapped_column(primary_key=True)
    at: Mapped[str] = mapped_column(default=now)
    user_id: Mapped[int | None] = mapped_column(ForeignKey('users.id'), nullable=True)
    action: Mapped[str] = mapped_column(String(80))
    entity: Mapped[str] = mapped_column(String(40))
    entity_id: Mapped[int] = mapped_column()
    info: Mapped[dict] = mapped_column(JSON, default=dict)
