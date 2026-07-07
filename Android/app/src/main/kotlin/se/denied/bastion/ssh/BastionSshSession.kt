package se.denied.bastion.ssh

import org.apache.sshd.client.SshClient
import org.apache.sshd.client.session.ClientSession
import org.apache.sshd.client.channel.ClientChannelEvent
import java.io.ByteArrayOutputStream
import java.util.EnumSet
import java.util.concurrent.TimeUnit

/**
 * Minsta gemensamma SSH-kärna på Android-sidan, motsvarande SSHSession.swift
 * (SSHCore) — men bara det som verkligen behövs för att bevisa att en
 * anslutning fungerar: connect/run/close på lösenordsautentisering. Jump
 * hosts, streaming exec och nyckelbaserad auth är UTELÄMNADE tills det finns
 * en verklig UI att koppla dem till, inte gissat i förväg.
 */
class BastionSshSession(
    private val host: String,
    private val port: Int,
    private val user: String,
) : AutoCloseable {

    private val client: SshClient = SshClient.setUpDefaultClient()
    private var session: ClientSession? = null

    fun connect(password: String, timeoutSeconds: Long = 10) {
        client.start()
        val s = client.connect(user, host, port)
            .verify(timeoutSeconds, TimeUnit.SECONDS)
            .session
        s.addPasswordIdentity(password)
        s.auth().verify(timeoutSeconds, TimeUnit.SECONDS)
        session = s
    }

    fun run(command: String, timeoutSeconds: Long = 10): String {
        val s = checkNotNull(session) { "connect() måste anropas innan run()" }
        val out = ByteArrayOutputStream()
        s.createExecChannel(command).use { channel ->
            channel.out = out
            channel.open().verify(timeoutSeconds, TimeUnit.SECONDS)
            channel.waitFor(
                EnumSet.of(ClientChannelEvent.CLOSED),
                TimeUnit.SECONDS.toMillis(timeoutSeconds),
            )
        }
        return out.toString(Charsets.UTF_8)
    }

    override fun close() {
        session?.close(false)
        client.stop()
    }
}
