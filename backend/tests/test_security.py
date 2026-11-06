"""0.11.0: login throttling in the database, idle sessions, security headers and short-lived connector links."""
from datetime import datetime, timezone, timedelta
from sqlalchemy import select, update
from app.db import Session
from app.models import Audit, LoginAttempt, LoginSession, ConnectorTicket
from test_connector_site import setup_reserved, ticket, as_connector, result, nfse_for, stored_xml, KEY

PASSWORD='Senha-ficticia-123!'

def login(client,username='administrador',password=PASSWORD):
    return client.post('/api/login',json={'username':username,'password':password})

def test_username_is_locked_after_five_failures_even_with_the_right_password(admin):
    admin.post('/api/logout')
    for _ in range(5):assert login(admin,password='Errada-ficticia-000').status_code==401
    r=login(admin);assert r.status_code==429 and '15 minutos' in r.json()['detail']
    with Session() as db:
        assert db.scalar(select(LoginAttempt).where(LoginAttempt.success.is_(True))) is None
        assert len(list(db.scalars(select(Audit).where(Audit.action=='login_failed'))))==5
        assert db.scalar(select(Audit).where(Audit.action=='login_blocked')) is not None
        assert all(len(a.ip_hash)==64 for a in db.scalars(select(LoginAttempt)))  # no address stored in clear
        # The window passes: the account opens again.
        db.execute(update(LoginAttempt).values(at=(datetime.now(timezone.utc)-timedelta(minutes=16)).isoformat()));db.commit()
    assert login(admin).status_code==200

def test_success_resets_the_username_counter(admin):
    admin.post('/api/logout')
    for _ in range(4):login(admin,password='Errada-ficticia-000')
    assert login(admin).status_code==200
    admin.post('/api/logout')
    for _ in range(4):login(admin,password='Errada-ficticia-000')
    assert login(admin).status_code==200

def test_unknown_users_are_throttled_per_client(admin):
    admin.post('/api/logout')
    for i in range(20):assert login(admin,username=f'inexistente{i}').status_code==401
    assert login(admin,username='outro-inexistente').status_code==429
    assert login(admin).status_code==429  # same client address

def test_idle_session_ends(admin):
    assert admin.get('/api/me').status_code==200
    with Session() as db:
        db.execute(update(LoginSession).values(last_seen=(datetime.now(timezone.utc)-timedelta(minutes=31)).isoformat()));db.commit()
    r=admin.get('/api/me');assert r.status_code==401 and 'inatividade' in r.json()['detail']
    with Session() as db:assert db.scalar(select(LoginSession)) is None

def test_active_session_is_kept_alive(admin):
    with Session() as db:
        db.execute(update(LoginSession).values(last_seen=(datetime.now(timezone.utc)-timedelta(minutes=20)).isoformat()));db.commit()
    assert admin.get('/api/me').status_code==200
    with Session() as db:assert db.scalar(select(LoginSession)).last_seen>(datetime.now(timezone.utc)-timedelta(minutes=1)).isoformat()

def test_security_headers(admin):
    h=admin.get('/api/me').headers
    assert h['x-frame-options']=='DENY' and h['x-content-type-options']=='nosniff' and h['cache-control']=='no-store'
    assert "frame-ancestors 'none'" in h['content-security-policy'] and "form-action 'self'" in h['content-security-policy']
    assert h['referrer-policy']=='same-origin' and 'camera=()' in h['permissions-policy']
    assert h['cross-origin-opener-policy']=='same-origin' and h['cross-origin-resource-policy']=='same-origin'

def test_connector_link_is_shortened_after_final_results(admin,company,row):
    ids=setup_reserved(admin,company,row)
    token,_=ticket(admin,ids);h=as_connector(admin,token)
    assert result(admin,h,ids[0],access_key=KEY,nfse_xml_b64=nfse_for(stored_xml(ids[0]))).status_code==200
    with Session() as db:
        t=db.scalar(select(ConnectorTicket))
        assert t.expires_at<=(datetime.now(timezone.utc)+timedelta(minutes=2,seconds=5)).isoformat()
        db.execute(update(ConnectorTicket).values(expires_at=(datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat()));db.commit()
    assert admin.get('/api/connector/jobs',headers=h).status_code==401
