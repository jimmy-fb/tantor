import logging
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt
from sqlalchemy.orm import Session

from app.config import settings
from app.models.user import User

logger = logging.getLogger("tantor.auth")


class AuthService:
    """Handles password hashing, JWT creation/validation, and user management."""

    @staticmethod
    def hash_password(password: str) -> str:
        return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()

    @staticmethod
    def verify_password(password: str, hashed: str) -> bool:
        return bcrypt.checkpw(password.encode(), hashed.encode())

    @staticmethod
    def create_access_token(user_id: str, role: str) -> str:
        payload = {
            "sub": user_id,
            "role": role,
            "type": "access",
            "exp": datetime.now(timezone.utc) + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES),
        }
        return jwt.encode(payload, settings.JWT_SECRET_KEY, algorithm="HS256")

    @staticmethod
    def create_refresh_token(user_id: str) -> str:
        payload = {
            "sub": user_id,
            "type": "refresh",
            "exp": datetime.now(timezone.utc) + timedelta(days=settings.REFRESH_TOKEN_EXPIRE_DAYS),
        }
        return jwt.encode(payload, settings.JWT_SECRET_KEY, algorithm="HS256")

    @staticmethod
    def decode_token(token: str) -> dict:
        return jwt.decode(token, settings.JWT_SECRET_KEY, algorithms=["HS256"])

    @staticmethod
    def authenticate(username: str, password: str, db: Session) -> User | None:
        user = db.query(User).filter(User.username == username, User.is_active == True).first()  # noqa: E712
        if user and AuthService.verify_password(password, user.hashed_password):
            user.last_login = datetime.now(timezone.utc)
            db.commit()
            return user
        return None

    @staticmethod
    def create_default_admin(db: Session):
        """Create default admin user if no users exist. Called on startup."""
        if db.query(User).count() == 0:
            admin = User(
                username="admin",
                hashed_password=AuthService.hash_password("admin"),
                role="admin",
            )
            db.add(admin)
            db.commit()
            logger.warning("Default admin user created (username: admin, password: admin). Change the password immediately!")
