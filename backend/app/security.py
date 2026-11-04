import hashlib
import secrets
from datetime import datetime, timezone, timedelta
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError, InvalidHashError
from fastapi import HTTPException, Request, Depends
from sqlalchemy import select
from .config import CLOUD
from .db import Session
from .models import User, LoginSession, Access

hasher = PasswordHasher()
def db_session():
    with Session() as db:
        yield db

def current_user(request: Request, db=Depends(db_session)):
    token = request.cookies.get('nfse_session', '')
    sess = db.get(LoginSession, hashlib.sha256(token.encode()).hexdigest())
    if not sess or sess.expires <= datetime.now(timezone.utc).isoformat():
        raise HTTPException(401, 'Entre no sistema')
    user = db.get(User, sess.user_id)
    if not user or not user.active:
        raise HTTPException(401, 'Usuário inativo')
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
    db.add(LoginSession(token_hash=hashlib.sha256(token.encode()).hexdigest(), user_id=user.id, expires=(datetime.now(timezone.utc)+timedelta(hours=8)).isoformat()))
    response.set_cookie('nfse_session',token,httponly=True,secure=CLOUD,samesite='strict',max_age=28800,path='/')
    db.commit()
