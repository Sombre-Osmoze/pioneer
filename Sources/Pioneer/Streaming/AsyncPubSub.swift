//
//  AsyncPubSub.swift
//  Pioneer
//
//  Created by d-exclaimation.
//

import Foundation

public struct AsyncPubSub: Sendable {
    public typealias Consumer = AsyncStream<Any>.Continuation
    
    public actor Engine {
        private var emitters: [String: Emitter] = [:]
        
        internal func subscribe(for key: String) async -> Emitter {
            let emitter = emitters.getOrElse(key) {
                .init()
            }
            emitters.update(key, with: emitter)
            return emitter
        }
        
        internal func asyncStream(for key: String) async -> AsyncStream<Any> {
            let emitter = await subscribe(for: key)
            let id = UUID().uuidString.lowercased()
            return AsyncStream<Any> { con in
                con.onTermination = { @Sendable _ in
                    Task {
                        await emitter.unsubscribe(id)
                    }
                }
                
                Task {
                    await emitter.subscribe(id, with: con)
                }
            }
            
        }
        
        internal func publish(for key: String, _ value: Any) async {
            await emitters[key]?.publish(value)
        }
        
        internal func close(for key: String) async {
            await emitters[key]?.close()
            emitters.delete(key)
        }
        
    }
    
    public actor Emitter {
        private var consumers: [String: Consumer] = [:]
        
        internal func subscribe(_ key: String, with consumer: Consumer) {
            consumers.update(key, with: consumer)
        }
        
        internal func unsubscribe(_ key: String) {
            consumers.delete(key)
        }
        
        internal func publish(_ value: Any) {
            consumers.values.forEach { consumer in
                consumer.yield(value)
            }
        }
        
        internal func close() {
            consumers.values.forEach { consumer in
                consumer.finish()
            }
            consumers.removeAll()
        }
    }
    
    private let engine: Engine = .init()
    
    public func asyncStream<DataType>(_ type: DataType.Type = DataType.self, for trigger: String) async -> AsyncStream<DataType> {
        let pipe = await engine.asyncStream(for: trigger)
        return AsyncStream<DataType> { con in
            let task = Task {
                for await untyped in pipe {
                    guard let typed = untyped as? DataType else { continue }
                    con.yield(typed)
                }
                con.finish()
            }
            con.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    public func publish(for trigger: String, payload: Any) async {
        await engine.publish(for: trigger, payload)
    }
    
    public func close(for trigger: String) async {
        await engine.close(for: trigger)
    }
}