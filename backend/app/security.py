import hashlib
import secrets
from datetime import datetime, timezone, timedelta
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError, InvalidHashError
from fastapi import HTTPException, Request, Depends
from sqlalchemy import select
from .config import CLOUD
from .db import Session
from sqlalchemy import delete, func
from .models import User, LoginSession, Access, LoginAttempt

hasher = PasswordHasher()
# Equal work for unknown users, so response time does not reveal which usernames exist.
DUMMY_HASH = hasher.hash(secrets.token_urlsafe(24))
# __Host- prefix: Secure, path=/ and no Domain, so a sibling subdomain can never set or overwrite it (HTTPS only).
COOKIE = '__Host-nfse_session' if CLOUD else 'nfse_session'
SESSION_HOURS = 8
IDLE_MINUTES = 30
LOCK_WINDOW_MINUTES = 15
MAX_USER_FAILURES = 5    # per username within the window
MAX_IP_FAILURES = 20     # per client address within the window

def utcnow():
    return datetime.now(timezone.utc)

def client_ip(request: Request) -> str:
    # On Vercel the platform sets X-Forwarded-For itself (clients cannot spoof the first hop). Locally, the socket address.
    if CLOUD:
        forwarded = request.headers.get('x-forwarded-for', '').split(',')[0].strip()
        if forwarded: return forwarded
        real = request.headers.get('x-real-ip', '').strip()
        if real: return real
    return request.client.host if request.client else 'local'

def ip_hash(ip: str) -> str:
    # Only a hash is stored: enough to throttle, without keeping client addresses in clear.
    return hashlib.sha256(('nfse-login:' + ip).encode()).hexdigest()

def login_blocked(db, username: str, ip: str) -> bool:
    since = (utcnow() - timedelta(minutes=LOCK_WINDOW_MINUTES)).isoformat()
    last_ok = db.scalar(select(func.max(LoginAttempt.at)).where(LoginAttempt.username == username, LoginAttempt.success.is_(True))) or ''
    user_failures = db.scalar(select(func.count()).select_from(LoginAttempt).where(LoginAttempt.username == username, LoginAttempt.success.is_(False), LoginAttempt.at >= max(since, last_ok)))
    ip_failures = db.scalar(select(func.count()).select_from(LoginAttempt).where(LoginAttempt.ip_hash == ip_hash(ip), LoginAttempt.success.is_(False), LoginAttempt.at >= since))
    return user_failures >= MAX_USER_FAILURES or ip_failures >= MAX_IP_FAILURES

def record_login(db, username: str, ip: str, success: bool):
    db.add(LoginAttempt(at=utcnow().isoformat(), username=username[:80], ip_hash=ip_hash(ip), success=success))
    # Housekeeping: attempts and expired sessions older than a day are no longer needed.
    old = (utcnow() - timedelta(days=1)).isoformat()
    db.execute(delete(LoginAttempt).where(LoginAttempt.at < old))
    db.execute(delete(LoginSession).where(LoginSession.expires < utcnow().isoformat()))
def db_session():
    with Session() as db:
        yield db

def current_user(request: Request, db=Depends(db_session)):
    token = request.cookies.get(COOKIE, '')
    sess = db.get(LoginSession, hashlib.sha256(token.encode()).hexdigest()) if token else None
    now = utcnow()
    if not sess or sess.expires <= now.isoformat():
        raise HTTPException(401, 'Entre no sistema')
    if sess.last_seen and sess.last_seen <= (now - timedelta(minutes=IDLE_MINUTES)).isoformat():
        db.delete(sess); db.commit()
        raise HTTPException(401, 'Sessão encerrada por inatividade. Entre novamente.')
    user = db.get(User, sess.user_id)
    if not user or not user.active:
        db.execute(delete(LoginSession).where(LoginSession.user_id == sess.user_id)); db.commit()
        raise HTTPException(401, 'Usuário inativo')
    # Refresh at most once a minute to avoid a write on every request.
    if not sess.last_seen or sess.last_seen <= (now - timedelta(minutes=1)).isoformat():
        sess.last_seen = now.isoformat(); db.commit()
    return user

def role(user, allowed):
    if user.role not in allowed:
        raise HTTPException(403, 'Seu perfil não permite esta operação')

def allowed_company(db, user, company_id):
    if user.role != 'admin' and not db.get(Access, (user.id,company_id)):
        raise HTTPException(403, 'Empresa não autorizada para este usuário')

def company_ids(db,user):
    if user.role == 'admin':
        return None
    return list(db.scalars(select(Access.company_id).where(Access.user_id==user.id)))

def issue_session(db,user,response):
    token = secrets.token_urlsafe(40)
    now = utcnow()
    db.add(LoginSession(token_hash=hashlib.sha256(token.encode()).hexdigest(), user_id=user.id, expires=(now+timedelta(hours=SESSION_HOURS)).isoformat(), last_seen=now.isoformat()))
    response.set_cookie(COOKIE,token,httponly=True,secure=CLOUD,samesite='strict',max_age=SESSION_HOURS*3600,path='/')
    db.commit()
