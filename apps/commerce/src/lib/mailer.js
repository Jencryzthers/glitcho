import nodemailer from 'nodemailer';

export function createMailer(config, logger) {
  if (!config.smtpHost) {
    return {
      enabled: false,
      async sendMagicLink({ email, loginURL }) {
        logger.info('mailer.disabled_magic_link', { email, loginURL });
        return { delivered: false, previewURL: loginURL };
      }
    };
  }

  const transporter = nodemailer.createTransport({
    host: config.smtpHost,
    port: config.smtpPort,
    secure: config.smtpSecure,
    auth: config.smtpUser
      ? {
          user: config.smtpUser,
          pass: config.smtpPass
        }
      : undefined
  });

  return {
    enabled: true,
    async sendMagicLink({ email, loginURL }) {
      await transporter.sendMail({
        from: config.smtpFrom,
        to: email,
        subject: 'Your Glitcho account sign-in link',
        text: `Open this link to sign in: ${loginURL}\n\nThis link expires in ${config.magicLinkTTLMinutes} minutes.`,
        html: `<p>Open this link to sign in:</p><p><a href="${loginURL}">${loginURL}</a></p><p>This link expires in ${config.magicLinkTTLMinutes} minutes.</p>`
      });
      logger.info('mailer.magic_link_sent', { email });
      return { delivered: true, previewURL: null };
    }
  };
}
